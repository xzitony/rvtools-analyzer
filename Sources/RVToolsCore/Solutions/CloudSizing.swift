import Foundation

/// Cloud right-sizing primitives shared by the built-in migration solutions and custom solutions
/// (exposed to scripts as `rva.cloud`), so both size and price VMs the same way.
public enum CloudSizing {
    /// Which hourly rate of an offer to use.
    public enum PriceModel: Equatable, Sendable {
        case payg, reserved1y, reserved3y
        /// A named rate from the offer's `prices` map (custom price lists), e.g. "savingsPlan1y".
        case named(String)

        public init(_ key: String) {
            switch key.lowercased() {
            case "", "payg", "ondemand", "on-demand", "linux": self = .payg
            case "reserved1y", "ri1y": self = .reserved1y
            case "reserved3y", "ri3y": self = .reserved3y
            default: self = .named(key)
            }
        }
    }

    public struct DemandOptions: Sendable {
        public var rightsizeCPU = false
        public var rightsizeMemory = false
        public var bufferPct = 25.0
        public var minVCPU = 1
        public var minMemoryGiB = 1.0
        /// Size disks from guest used space (plus headroom) instead of provisioned capacity.
        public var diskFromGuestUsage = false
        public var diskHeadroomPct = 20.0
        public init() {}
    }

    public struct Demand: Sendable {
        public let vcpu: Int
        public let memoryGiB: Double
        public let windows: Bool
        public let diskGiB: [Double]
        public let rightsized: Bool
    }

    public struct Fit: Sendable {
        public let offer: InstanceOffer
        public let hourly: Double
    }

    public struct Disk: Sendable {
        public let label: String
        public let gib: Double
        public let monthly: Double
        public let oversize: Bool
    }

    /// Target size for a VM: configured size, or observed usage × (1 + buffer) when right-sizing, never below the minimums.
    public static func demand(_ vm: VM, _ o: DemandOptions, hostSpeedMHz: Double?) -> Demand {
        let buffer = 1 + o.bufferPct / 100
        var cpu = vm.cpus, mem = vm.memoryMiB / 1024, changed = false
        if o.rightsizeCPU, vm.isRunning, vm.cpuUsageMHz > 0, let speed = hostSpeedMHz, speed > 0 {
            let needed = Int((vm.cpuUsageMHz / speed * buffer).rounded(.up))
            if needed < cpu { cpu = needed; changed = true }
        }
        if o.rightsizeMemory, vm.isRunning, vm.memConsumedMiB > 0 {
            let needed = vm.memConsumedMiB / 1024 * buffer
            if needed < mem { mem = needed; changed = true }
        }
        cpu = max(cpu, o.minVCPU)
        mem = max(mem, o.minMemoryGiB)

        var sizes = vm.disks.isEmpty ? [max(vm.provisionedMiB / 1024, 1)] : vm.disks.map { max($0.capacityMiB / 1024, 1) }
        if o.diskFromGuestUsage {
            let used = (vm.guestConsumedMiB > 0 ? vm.guestConsumedMiB : vm.inUseExcludingSwapMiB) / 1024 * (1 + o.diskHeadroomPct / 100)
            let total = sizes.reduce(0, +)
            if total > 0, used > 0, used < total { sizes = sizes.map { max(1, $0 / total * used) } }
        }
        let windows = vm.os.family == .windowsServer || vm.os.family == .windowsDesktop
        return Demand(vcpu: cpu, memoryGiB: mem, windows: windows, diskGiB: sizes, rightsized: changed)
    }

    /// Hourly price of an offer (nil if it can't be bought that way). The discount applies to the base rate;
    /// the Windows licence uplift (Windows − Linux rate) is never discounted.
    public static func hourly(_ o: InstanceOffer, windows: Bool, licenseIncluded: Bool, model: PriceModel, discountPct: Double) -> Double? {
        guard let linux = o.linuxHourly else { return nil }
        var license = 0.0
        if windows && licenseIncluded {
            guard let win = o.windowsHourly else { return nil }
            license = max(0, win - linux)
        }
        let base: Double
        switch model {
        case .payg: base = linux
        case .reserved1y: base = o.reserved1yHourly ?? linux
        case .reserved3y: base = o.reserved3yHourly ?? linux
        case .named(let key): base = o.prices?[key] ?? linux
        }
        return (discountPct == 0 ? base : base * (1 - discountPct / 100)) + license
    }

    /// The cheapest offer with at least the demanded vCPU and memory (ties go to the smaller instance).
    public static func bestFit(vcpu: Int, memoryGiB: Double, windows: Bool, offers: [InstanceOffer],
                               licenseIncluded: Bool, model: PriceModel, discountPct: Double) -> Fit? {
        offers.filter { $0.vcpu >= vcpu && $0.memoryGiB >= memoryGiB - 0.01 }
            .compactMap { o in hourly(o, windows: windows, licenseIncluded: licenseIncluded, model: model, discountPct: discountPct).map { Fit(offer: o, hourly: $0) } }
            .min { ($0.hourly, $0.offer.vcpu, $0.offer.memoryGiB) < ($1.hourly, $1.offer.vcpu, $1.offer.memoryGiB) }
    }

    static let azureTiers: [(num: Int, gib: Double)] = [(1, 4), (2, 8), (3, 16), (4, 32), (6, 64), (10, 128), (15, 256), (20, 512), (30, 1024),
                                                        (40, 2048), (50, 4096), (60, 8192), (70, 16384), (80, 32767)]

    /// An Azure managed disk rounded up to the next tier; disks over 32 TiB are split. `prefix`: P (Premium SSD), E (Standard SSD), S (Standard HDD).
    public static func azureManagedDisk(gib: Double, prefix: String, storage: [String: Double]) -> Disk {
        let count = max(1, (gib / 32767).rounded(.up))
        let per = gib / count
        for t in azureTiers where t.gib >= per - 0.001 {
            if let price = storage["\(prefix)\(t.num)"] {
                return Disk(label: count > 1 ? "\(Int(count))× \(prefix)\(t.num)" : "\(prefix)\(t.num)", gib: gib, monthly: price * count, oversize: count > 1)
            }
        }
        return Disk(label: "n/a", gib: gib, monthly: 0, oversize: false)
    }

    /// An EBS volume of the same size (st1 has a 125 GiB minimum). `type`: gp3, gp2 or st1.
    public static func awsVolume(gib: Double, type: String, storage: [String: Double]) -> Disk {
        let size = type == "st1" ? max(gib, 125) : gib
        return Disk(label: type, gib: size, monthly: (storage[type] ?? 0) * size, oversize: gib > 16_384)
    }
}
