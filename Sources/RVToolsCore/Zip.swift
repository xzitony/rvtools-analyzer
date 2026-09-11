import Foundation
import Compression

public enum RVToolsError: LocalizedError {
    case unreadable(String)
    case corrupt(String)
    case notRVTools(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let s), .corrupt(let s), .notRVTools(let s): return s
        }
    }
}

struct ZipEntry {
    let name: String
    let method: Int
    let compressedSize: Int
    let uncompressedSize: Int
    let localHeaderOffset: Int
}

/// Minimal read-only ZIP reader (stored + deflate, ZIP64 aware). An .xlsx is a ZIP of XML parts,
/// so this is all we need to avoid third-party dependencies.
final class ZipArchive {
    private let data: Data
    private var entries: [String: ZipEntry] = [:]
    private var lowercased: [String: ZipEntry] = [:]

    init(url: URL) throws {
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) } catch {
            throw RVToolsError.unreadable("Could not read \(url.lastPathComponent): \(error.localizedDescription)")
        }
        try readCentralDirectory()
    }

    func contains(_ path: String) -> Bool { entry(path) != nil }

    func read(_ path: String) throws -> Data {
        guard let e = entry(path) else { throw RVToolsError.corrupt("Workbook part \(path) is missing") }
        let lh = e.localHeaderOffset
        guard try u32(lh) == 0x0403_4B50 else { throw RVToolsError.corrupt("Bad ZIP local header for \(path)") }
        let start = lh + 30 + (try u16(lh + 26)) + (try u16(lh + 28))
        guard start >= 0, start + e.compressedSize <= data.count else { throw RVToolsError.corrupt("ZIP entry \(path) is truncated") }
        let comp = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + e.compressedSize))
        switch e.method {
        case 0: return comp
        case 8: return try Inflate.raw(comp, expectedSize: e.uncompressedSize)
        default: throw RVToolsError.corrupt("Unsupported ZIP compression method \(e.method) for \(path)")
        }
    }

    private func entry(_ path: String) -> ZipEntry? {
        entries[path] ?? lowercased[path.lowercased()]
    }

    private func u16(_ o: Int) throws -> Int {
        guard o >= 0, o + 2 <= data.count else { throw RVToolsError.corrupt("ZIP structure is truncated") }
        let b = data.startIndex + o
        return Int(data[b]) | Int(data[b + 1]) << 8
    }

    private func u32(_ o: Int) throws -> Int {
        let lo = try u16(o), hi = try u16(o + 2)
        return lo | hi << 16
    }

    private func u64(_ o: Int) throws -> Int {
        let lo = try u32(o), hi = try u32(o + 4)
        return lo | hi << 32
    }

    private func readCentralDirectory() throws {
        let eocdSize = 22
        guard data.count >= eocdSize else { throw RVToolsError.notRVTools("File is too small to be an .xlsx workbook") }
        var eocd = -1
        var p = data.count - eocdSize
        let lower = max(0, data.count - eocdSize - 0xFFFF)
        while p >= lower {
            if data[data.startIndex + p] == 0x50, try u32(p) == 0x0605_4B50 { eocd = p; break }
            p -= 1
        }
        guard eocd >= 0 else { throw RVToolsError.notRVTools("File is not a valid .xlsx (ZIP) workbook") }

        var count = try u16(eocd + 10)
        var cdOffset = try u32(eocd + 16)
        if count == 0xFFFF || cdOffset == 0xFFFF_FFFF {
            let locator = eocd - 20
            if locator >= 0, try u32(locator) == 0x0706_4B50 {
                let z = try u64(locator + 8)
                guard try u32(z) == 0x0606_4B50 else { throw RVToolsError.corrupt("Bad ZIP64 directory record") }
                count = try u64(z + 32)
                cdOffset = try u64(z + 48)
            }
        }

        var q = cdOffset
        for _ in 0..<count {
            guard try u32(q) == 0x0201_4B50 else { throw RVToolsError.corrupt("Bad ZIP central directory") }
            let method = try u16(q + 10)
            var csize = try u32(q + 20)
            var usize = try u32(q + 24)
            let nameLen = try u16(q + 28), extraLen = try u16(q + 30), commentLen = try u16(q + 32)
            var offset = try u32(q + 42)
            let nameStart = q + 46
            guard nameStart + nameLen <= data.count else { throw RVToolsError.corrupt("ZIP entry name is truncated") }
            let nameBytes = data[(data.startIndex + nameStart)..<(data.startIndex + nameStart + nameLen)]
            let name = String(decoding: nameBytes, as: UTF8.self).replacingOccurrences(of: "\\", with: "/")

            var e = nameStart + nameLen
            let extraEnd = e + extraLen
            while e + 4 <= extraEnd {
                let id = try u16(e), size = try u16(e + 2)
                if id == 0x0001 {
                    var f = e + 4
                    if usize == 0xFFFF_FFFF { usize = try u64(f); f += 8 }
                    if csize == 0xFFFF_FFFF { csize = try u64(f); f += 8 }
                    if offset == 0xFFFF_FFFF { offset = try u64(f) }
                }
                e += 4 + size
            }
            let entry = ZipEntry(name: name, method: method, compressedSize: csize, uncompressedSize: usize, localHeaderOffset: offset)
            entries[name] = entry
            lowercased[name.lowercased()] = entry
            q = extraEnd + commentLen
        }
    }
}

enum Inflate {
    /// Raw DEFLATE (RFC 1951) — Apple's COMPRESSION_ZLIB is headerless deflate, exactly what ZIP stores.
    static func raw(_ input: Data, expectedSize: Int) throws -> Data {
        if input.isEmpty { return Data() }
        if expectedSize > 0 {
            var out = Data(count: expectedSize)
            let written = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
                input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                                              src.bindMemory(to: UInt8.self).baseAddress!, input.count,
                                              nil, COMPRESSION_ZLIB)
                }
            }
            if written == expectedSize { return out }
        }
        return try stream(input)
    }

    private static func stream(_ input: Data) throws -> Data {
        let sp = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { sp.deallocate() }
        guard compression_stream_init(sp, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw RVToolsError.corrupt("Could not initialise decompression")
        }
        defer { compression_stream_destroy(sp) }
        let chunk = 1 << 20
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buf.deallocate() }
        var out = Data()
        try input.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            sp.pointee.src_ptr = src.bindMemory(to: UInt8.self).baseAddress!
            sp.pointee.src_size = input.count
            while true {
                sp.pointee.dst_ptr = buf
                sp.pointee.dst_size = chunk
                let status = compression_stream_process(sp, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - sp.pointee.dst_size
                if produced > 0 { out.append(buf, count: produced) }
                if status == COMPRESSION_STATUS_END { break }
                guard status == COMPRESSION_STATUS_OK else { throw RVToolsError.corrupt("Workbook data is corrupt (inflate failed)") }
                if produced == 0 && sp.pointee.src_size == 0 { break }
            }
        }
        return out
    }
}
