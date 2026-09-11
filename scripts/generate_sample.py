#!/usr/bin/env python3
"""Generate a synthetic RVTools export (xlsx + "export all to csv" folder) for demos and tests.

All names, addresses and serials are fictional. The environment deliberately contains issues
(old snapshots, EOL guests, full datastores, N+1 shortfalls, dead paths, duplicate IPs, ...)
so every dashboard section has something to show.

usage: python3 scripts/generate_sample.py [output-dir]      (requires openpyxl)
"""
import csv
import datetime as dt
import os
import random
import sys

from openpyxl import Workbook

R = random.Random(42)
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "samples")
EXPORT = dt.datetime(2026, 9, 1, 9, 30, 0)
VC = "vcsa01.corp.example"
VCUUID = "5f3c9a8e-1b2d-4c7e-9a10-2f6b8d4e7c31"
MIB_GB = 1024
MIB_TB = 1024 * 1024

VM_TAIL = ["Annotation", "CBT Reset Lock", "NB_LAST_BACKUP", "DataProtection", "Datacenter", "Cluster", "Host", "Folder",
           "OS according to the configuration file", "OS according to the VMware Tools", "VM ID", "VM UUID", "VI SDK Server", "VI SDK UUID"]
HEADERS = {
    "vInfo": ["VM", "Powerstate", "Template", "SRM Placeholder", "Config status", "DNS Name", "Connection state", "Guest state", "Heartbeat",
              "Consolidation Needed", "PowerOn", "Suspended To Memory", "Suspend time", "Suspend Interval", "Creation date", "Change Version", "CPUs",
              "Overall Cpu Readiness", "Memory", "Active Memory", "NICs", "Disks", "Total disk capacity MiB", "Fixed Passthru HotPlug",
              "min Required EVC Mode Key", "Latency Sensitivity", "Op Notification Timeout", "EnableUUID", "CBT", "Primary IP Address",
              "Network #1", "Network #2", "Network #3", "Network #4", "Network #5", "Network #6", "Network #7", "Network #8", "Num Monitors",
              "Video Ram KiB", "Resource pool", "Folder ID", "Folder", "vApp", "DAS protection", "FT State", "FT Role", "FT Latency", "FT Bandwidth",
              "FT Sec. Latency", "Vm Failover In Progress", "Provisioned MiB", "In Use MiB", "Unshared MiB", "HA Restart Priority",
              "HA Isolation Response", "HA VM Monitoring", "Cluster rule(s)", "Cluster rule name(s)", "Boot Required", "Boot delay",
              "Boot retry delay", "Boot retry enabled", "Boot BIOS setup", "Reboot PowerOff", "EFI Secure boot", "Firmware", "HW version",
              "HW upgrade status", "HW upgrade policy", "HW target", "Path", "Log directory", "Snapshot directory", "Suspend directory",
              "Annotation", "CBT Reset Lock", "NB_LAST_BACKUP", "DataProtection", "Datacenter", "Cluster", "Host",
              "OS according to the configuration file", "OS according to the VMware Tools", "Customization Info", "Guest Detailed Data",
              "VM ID", "SMBIOS UUID", "VM UUID", "VI SDK Server type", "VI SDK API Version", "VI SDK Server", "VI SDK UUID"],
    "vCPU": ["VM", "Powerstate", "Template", "SRM Placeholder", "CPUs", "Sockets", "Cores p/s", "Max", "Overall", "Level", "Shares", "Reservation",
             "Entitlement", "DRS Entitlement", "Limit", "Hot Add", "Hot Remove", "Numa Hotadd Exposed"] + VM_TAIL,
    "vMemory": ["VM", "Powerstate", "Template", "SRM Placeholder", "Size MiB", "Memory Reservation Locked To Max", "Overhead", "Max", "Consumed",
                "Consumed Overhead", "Private", "Shared", "Swapped", "Ballooned", "Active", "Entitlement", "DRS Entitlement", "Level", "Shares",
                "Reservation", "Limit", "Hot Add"] + VM_TAIL,
    "vDisk": ["VM", "Powerstate", "Template", "SRM Placeholder", "Disk", "Disk Key", "Disk UUID", "Disk Path", "Capacity MiB", "Raw", "Disk Mode",
              "Sharing mode", "Thin", "Eagerly Scrub", "Split", "Write Through", "Level", "Shares", "Reservation", "Limit", "Controller", "Label",
              "SCSI Unit #", "Unit #", "Shared Bus", "Path", "Raw LUN ID", "Raw Comp. Mode", "Internal Sort Column"] + VM_TAIL,
    "vPartition": ["VM", "Powerstate", "Template", "SRM Placeholder", "Disk Key", "Disk", "Capacity MiB", "Consumed MiB", "Free MiB", "Free %",
                   "Internal Sort Column"] + VM_TAIL,
    "vNetwork": ["VM", "Powerstate", "Template", "SRM Placeholder", "NIC label", "Adapter", "Network", "Switch", "Connected", "Starts Connected",
                 "Mac Address", "Type", "IPv4 Address", "IPv6 Address", "Direct Path IO", "Internal Sort Column"] + VM_TAIL,
    "vCD": ["VM", "Powerstate", "Template", "SRM Placeholder", "Device Node", "Connected", "Starts Connected", "Device Type"] + VM_TAIL[:10] + ["VMRef"] + VM_TAIL[10:],
    "vUSB": ["VM", "Powerstate", "Template", "SRM Placeholder", "Device Node", "Device Type", "Connected", "Family", "Speed", "EHCI enabled",
             "Auto connect", "Bus number", "Unit number"] + VM_TAIL[:10] + ["VMRef"] + VM_TAIL[10:],
    "vSnapshot": ["VM", "Powerstate", "Name", "Description", "Date / time", "Filename", "Size MiB (vmsn)", "Size MiB (total)", "Quiesced", "State"] + VM_TAIL,
    "vTools": ["VM", "Powerstate", "Template", "SRM Placeholder", "VM Version", "Tools", "Tools Version", "Required Version", "Upgradeable",
               "Upgrade Policy", "Sync time", "App status", "Heartbeat status", "Kernel Crash state", "Operation Ready", "State change support",
               "Interactive Guest"] + VM_TAIL[:10] + ["VMRef"] + VM_TAIL[10:],
    "vSource": ["Name", "OS type", "API type", "API version", "Version", "Patch level", "Build", "Fullname", "Product name", "Product version",
                "Product line", "Vendor", "VI SDK Server", "VI SDK UUID"],
    "vRP": ["Resource Pool name", "Resource Pool path", "Status", "# VMs total", "# VMs", "# vCPUs", "CPU limit", "CPU overheadLimit",
            "CPU reservation", "CPU level", "CPU shares", "CPU expandableReservation", "CPU maxUsage", "CPU overallUsage", "Mem Configured",
            "Mem limit", "Mem reservation", "Mem level", "Mem shares", "Object ID", "VI SDK Server", "VI SDK UUID"],
    "vCluster": ["Name", "Config status", "OverallStatus", "NumHosts", "numEffectiveHosts", "TotalCpu", "NumCpuCores", "NumCpuThreads",
                 "Effective Cpu", "TotalMemory", "Effective Memory", "Num VMotions", "HA enabled", "Failover Level", "AdmissionControlEnabled",
                 "Host monitoring", "HB Datastore Candidate Policy", "Isolation Response", "Restart Priority", "Cluster Settings", "Max Failures",
                 "Max Failure Window", "Failure Interval", "Min Up Time", "VM Monitoring", "DRS enabled", "DRS default VM behavior",
                 "DRS vmotion rate", "DPM enabled", "DPM default behavior", "DPM Host Power Action Rate", "Object ID", "VI SDK Server", "VI SDK UUID"],
    "vHost": ["Host", "Datacenter", "Cluster", "Config status", "Compliance Check State", "in Maintenance Mode", "in Quarantine Mode",
              "vSAN Fault Domain Name", "CPU Model", "Speed", "HT Available", "HT Active", "# CPU", "Cores per CPU", "# Cores", "CPU usage %",
              "# Memory", "Memory Tiering Type", "Memory usage %", "Console", "# NICs", "# HBAs", "# VMs total", "# VMs", "VMs per Core", "# vCPUs",
              "vCPUs per Core", "vRAM", "VM Used memory", "VM Memory Swapped", "VM Memory Ballooned", "VMotion support", "Storage VMotion support",
              "Current EVC", "Max EVC", "Assigned License(s)", "ATS Heartbeat", "ATS Locking", "Current CPU power man. policy",
              "Supported CPU power man.", "Host Power Policy", "ESX Version", "Boot time", "DNS Servers", "DHCP", "Domain", "Domain List",
              "DNS Search Order", "NTP Server(s)", "NTPD running", "Time Zone", "Time Zone Name", "GMT Offset", "Vendor", "Model", "Serial number",
              "Service tag", "OEM specific string", "BIOS Vendor", "BIOS Version", "BIOS Date", "Certificate Issuer", "Certificate Start Date",
              "Certificate Expiry Date", "Certificate Status", "Certificate Subject", "Object ID", "AutoDeploy.MachineIdentity", "UUID",
              "VI SDK Server", "VI SDK UUID"],
    "vHBA": ["Host", "Datacenter", "Cluster", "Device", "Type", "Status", "Bus", "Pci", "Driver", "Model", "WWN", "VI SDK Server", "VI SDK UUID"],
    "vNIC": ["Host", "Datacenter", "Cluster", "Network Device", "Driver", "Speed", "Duplex", "MAC", "Switch", "Uplink port", "PCI", "WakeOn",
             "VI SDK Server", "VI SDK UUID"],
    "vSwitch": ["Host", "Datacenter", "Cluster", "Switch", "# Ports", "Free Ports", "Promiscuous Mode", "Mac Changes", "Forged Transmits",
                "Traffic Shaping", "Width", "Peak", "Burst", "Policy", "Reverse Policy", "Notify Switch", "Rolling Order", "Offload", "TSO",
                "Zero Copy Xmit", "MTU", "VI SDK Server", "VI SDK UUID"],
    "vPort": ["Host", "Datacenter", "Cluster", "Port Group", "Switch", "VLAN", "Promiscuous Mode", "Mac Changes", "Forged Transmits",
              "Traffic Shaping", "Width", "Peak", "Burst", "Policy", "Reverse Policy", "Notify Switch", "Rolling Order", "Offload", "TSO",
              "Zero Copy Xmit", "VI SDK Server", "VI SDK UUID"],
    "dvSwitch": ["Switch", "Datacenter", "Name", "Vendor", "Version", "Description", "Created", "Host members", "Max Ports", "# Ports", "# VMs",
                 "In Traffic Shaping", "In Avg", "In Peak", "In Burst", "Out Traffic Shaping", "Out Avg", "Out Peak", "Out Burst", "CDP Type",
                 "CDP Operation", "LACP Name", "LACP Mode", "LACP Load Balance Alg.", "Max MTU", "Contact", "Admin Name", "Object ID",
                 "VI SDK Server", "VI SDK UUID"],
    "dvPort": ["Port", "Switch", "Type", "# Ports", "VLAN", "Speed", "Full Duplex", "Blocked", "Allow Promiscuous", "Mac Changes", "Active Uplink",
               "Standby Uplink", "Policy", "Forged Transmits", "In Traffic Shaping", "Out Traffic Shaping", "Reverse Policy", "Notify Switch",
               "Rolling Order", "Check Beacon", "Object ID", "VI SDK Server", "VI SDK UUID"],
    "vSC_VMK": ["Host", "Datacenter", "Cluster", "Port Group", "Device", "Mac Address", "DHCP", "IP Address", "IP 6 Address", "Subnet mask",
                "Gateway", "IP 6 Gateway", "MTU", "VI SDK Server", "VI SDK UUID"],
    "vDatastore": ["Name", "Config status", "Address", "Accessible", "Type", "# VMs total", "# VMs", "Capacity MiB", "Provisioned MiB",
                   "In Use MiB", "Free MiB", "Free %", "SIOC enabled", "SIOC Threshold", "# Hosts", "Hosts", "Cluster name",
                   "Cluster capacity MiB", "Cluster free space MiB", "Block size", "Max Blocks", "# Extents", "Major Version", "Version",
                   "VMFS Upgradeable", "MHA", "URL", "Object ID", "VI SDK Server", "VI SDK UUID"],
    "vMultiPath": ["Host", "Cluster", "Datacenter", "Datastore", "Disk", "Display name", "Policy", "Oper. State", "Path 1", "Path 1 state",
                   "Path 2", "Path 2 state", "Path 3", "Path 3 state", "Path 4", "Path 4 state", "Path 5", "Path 5 state", "Path 6", "Path 6 state",
                   "Path 7", "Path 7 state", "Path 8", "Path 8 state", "vStorage", "Queue depth", "Vendor", "Model", "Revision", "Level",
                   "Serial #", "UUID", "Object ID", "VI SDK Server", "VI SDK UUID"],
    "vLicense": ["Name", "Key", "Labels", "Cost Unit", "Total", "Used", "Expiration Date", "Features", "VI SDK Server", "VI SDK UUID"],
    "vFileInfo": ["Friendly Path Name", "File Name", "File Type", "File Size in bytes", "Path", "Internal Sort Column", "VI SDK Server", "VI SDK UUID"],
    "vHealth": ["Name", "Message", "Message type", "VI SDK Server", "VI SDK UUID"],
    "vMetaData": ["RVTools major version", "RVTools version", "xlsx creation datetime", "Server"],
}
rows = {k: [] for k in HEADERS}


def tf(b):
    return "True" if b else "False"


def days_ago(d, jitter_hours=True):
    return EXPORT - dt.timedelta(days=d, hours=R.randint(0, 23) if jitter_hours else 0, minutes=R.randint(0, 59))


# ---------------------------------------------------------------- hosts & clusters
CLUSTERS = [
    # name, dc, hosts, esx builds, cpu models, sockets, cores/socket, memory MiB, vendor/model, cpu%, mem%, HA, AC, DRS
    dict(name="Prod-Cluster", dc="DC-East", n=6, esx=["VMware ESXi 8.0.2 build-24790513"] * 6,
         cpu=["Intel(R) Xeon(R) Gold 6338 CPU @ 2.00GHz"] * 6, sockets=2, cps=32, mem=1048576, vendor="Dell Inc.", model="PowerEdge R750",
         cpu_pct=[48, 55, 61, 44, 52, 58], mem_pct=[78, 83, 92, 74, 80, 77], ha=True, ac=True, drs=True, speed=2000),
    dict(name="Dev-Cluster", dc="DC-East", n=3, esx=["VMware ESXi 7.0.3 build-21930508", "VMware ESXi 7.0.3 build-21930508", "VMware ESXi 8.0.2 build-24790513"],
         cpu=["Intel(R) Xeon(R) Gold 6130 CPU @ 2.10GHz", "Intel(R) Xeon(R) Gold 6130 CPU @ 2.10GHz", "Intel(R) Xeon(R) Gold 6338 CPU @ 2.00GHz"],
         sockets=2, cps=16, mem=393216, vendor="HPE", model="ProLiant DL380 Gen10", cpu_pct=[31, 27, 22], mem_pct=[66, 71, 58], ha=True, ac=True, drs=False, speed=2100),
    dict(name="Mgmt-Cluster", dc="DC-West", n=2, esx=["VMware ESXi 6.7.0 build-17700523"] * 2,
         cpu=["Intel(R) Xeon(R) CPU E5-2680 v4 @ 2.40GHz"] * 2, sockets=2, cps=14, mem=262144, vendor="Cisco Systems Inc", model="UCSC-C240-M4SX",
         cpu_pct=[52, 49], mem_pct=[91, 93], ha=False, ac=False, drs=True, speed=2400),
    dict(name="", dc="DC-West", n=1, esx=["VMware ESXi 7.0.3 build-21930508"], cpu=["Intel(R) Xeon(R) Silver 4210 CPU @ 2.20GHz"],
         sockets=1, cps=10, mem=131072, vendor="Supermicro", model="SYS-1029P", cpu_pct=[18], mem_pct=[55], ha=None, ac=None, drs=None, speed=2200),
]
hosts = []
for c in CLUSTERS:
    prefix = {"Prod-Cluster": "esx-prod", "Dev-Cluster": "esx-dev", "Mgmt-Cluster": "esx-mgmt", "": "esx-dmz"}[c["name"]]
    for i in range(c["n"]):
        hosts.append(dict(name=f"{prefix}{i + 1:02d}.corp.example", cluster=c["name"], dc=c["dc"], esx=c["esx"][i], cpu=c["cpu"][i],
                          sockets=c["sockets"], cps=c["cps"], mem=c["mem"], vendor=c["vendor"], model=c["model"], cpu_pct=c["cpu_pct"][i],
                          mem_pct=c["mem_pct"][i], speed=c["speed"], vms=[], idx=len(hosts)))
hosts_by_cluster = {c["name"]: [h for h in hosts if h["cluster"] == c["name"]] for c in CLUSTERS}

# ---------------------------------------------------------------- datastores
datastores = []


def add_ds(name, dtype, cap_tb, hs, major=6, url=None):
    datastores.append(dict(name=name, type=dtype, cap=int(cap_tb * MIB_TB), hosts=hs, major=major, vms=set(), prov=0, used=0, url=url or f"ds:///vmfs/volumes/{R.getrandbits(64):016x}/"))


for i in range(1, 6):
    add_ds(f"prod-vmfs-{i:02d}", "VMFS", 20, hosts_by_cluster["Prod-Cluster"])
add_ds("dev-nfs-01", "NFS", 10, hosts_by_cluster["Dev-Cluster"])
add_ds("dev-nfs-02", "NFS", 10, hosts_by_cluster["Dev-Cluster"])
add_ds("mgmt-vsan", "vsan", 30, hosts_by_cluster["Mgmt-Cluster"])
add_ds("iso-library", "NFS", 2, hosts_by_cluster["Prod-Cluster"] + hosts_by_cluster["Dev-Cluster"])
for h in hosts:
    add_ds(h["name"].split(".")[0] + "-local", "VMFS", 0.4 if "dmz" not in h["name"] else 3.5, [h], major=5 if "mgmt" in h["name"] else 6)
ds_by_name = {d["name"]: d for d in datastores}

# ---------------------------------------------------------------- guest OS catalogue: (config, tools, weight, family)
OSES = [
    ("Microsoft Windows Server 2019 (64-bit)", "Microsoft Windows Server 2019 Standard", 28, "win"),
    ("Microsoft Windows Server 2016 or later (64-bit)", "Microsoft Windows Server 2022 Datacenter", 20, "win"),
    ("Microsoft Windows Server 2016 (64-bit)", "Microsoft Windows Server 2016 Standard", 14, "win"),
    ("Microsoft Windows Server 2012 (64-bit)", "Microsoft Windows Server 2012 R2 Standard", 8, "win"),
    ("Microsoft Windows Server 2008 R2 (64-bit)", "Microsoft Windows Server 2008 R2 Enterprise", 3, "win"),
    ("Red Hat Enterprise Linux 8 (64-bit)", "Red Hat Enterprise Linux 8.8 (Ootpa)", 8, "lin"),
    ("Red Hat Enterprise Linux 9 (64-bit)", "Red Hat Enterprise Linux 9.2 (Plow)", 4, "lin"),
    ("CentOS 7 (64-bit)", "CentOS Linux 7 (Core)", 5, "lin"),
    ("Ubuntu Linux (64-bit)", "Ubuntu 22.04.4 LTS", 5, "lin"),
    ("Ubuntu Linux (64-bit)", "Ubuntu 18.04.6 LTS", 2, "lin"),
    ("SUSE Linux Enterprise 15 (64-bit)", "SUSE Linux Enterprise Server 15 SP5", 2, "lin"),
    ("Microsoft Windows 10 (64-bit)", "Microsoft Windows 10 Enterprise", 2, "win"),
    ("Other 3.x or later Linux (64-bit)", "", 1, "lin"),
]


def pick_os():
    return R.choices(OSES, weights=[o[2] for o in OSES])[0]


NETS = {"Prod-Cluster": [("PG-App-100", "10.10.100."), ("PG-DB-110", "10.10.110."), ("PG-Web-120", "10.10.120.")],
        "Dev-Cluster": [("PG-Dev-200", "10.20.200."), ("PG-Nested-Lab-250", "10.20.250.")],
        "Mgmt-Cluster": [("PG-Mgmt-VMs-15", "10.0.15.")],
        "": [("DMZ-Net", "172.16.30.")]}
ip_counter = {}
mac_counter = [0x100]
vms = []


def next_ip(prefix):
    ip_counter[prefix] = ip_counter.get(prefix, 10) + 1
    return prefix + str(ip_counter[prefix])


def next_mac():
    mac_counter[0] += 1
    m = mac_counter[0]
    return f"00:50:56:{(m >> 16) & 0xff:02x}:{(m >> 8) & 0xff:02x}:{m & 0xff:02x}"


def make_vm(name, cluster, host, os_entry=None, template=False, cpus=None, mem_gb=None, power=None):
    cfg, tools, _, fam = os_entry or pick_os()
    cpus = cpus or R.choice([1, 2, 2, 2, 4, 4, 4, 4, 8, 8, 12, 16])
    mem_gb = mem_gb or R.choice([2, 4, 4, 8, 8, 8, 16, 16, 24, 32, 64]) * (1 if cpus < 8 else 2)
    power = power or ("poweredOff" if template else R.choices(["poweredOn", "poweredOff", "suspended"], [88, 10, 2])[0])
    vm = dict(name=name, cluster=cluster, host=host, cfg=cfg, tools_os=tools, fam=fam, cpus=cpus, mem=mem_gb * 1024, power=power,
              template=template, id=f"vm-{1000 + len(vms)}", uuid=f"42{R.getrandbits(120):030x}", disks=[], nics=[], snaps=[],
              hw=R.choices([21, 20, 19, 17, 14, 13, 11, 10, 9], [10, 30, 15, 12, 12, 8, 7, 4, 2])[0],
              created=days_ago(R.randint(20, 3400)), dc=host["dc"])
    vms.append(vm)
    host["vms"].append(vm)
    return vm


def cluster_ds(cluster):
    return {"Prod-Cluster": [f"prod-vmfs-{i:02d}" for i in range(1, 6)], "Dev-Cluster": ["dev-nfs-01", "dev-nfs-02"],
            "Mgmt-Cluster": ["mgmt-vsan"], "": ["esx-dmz01-local"]}[cluster]


roles = ["APP", "APP", "APP", "WEB", "WEB", "SQL", "FS", "RDS", "SVC", "CTX"]
for i in range(220):
    make_vm(f"PRD-{R.choice(roles)}-{i + 1:03d}", "Prod-Cluster", R.choice(hosts_by_cluster["Prod-Cluster"]))
for i in range(90):
    make_vm(f"DEV-{R.choice(roles)}-{i + 1:03d}", "Dev-Cluster", R.choice(hosts_by_cluster["Dev-Cluster"]))
mgmt_names = ["vcsa01", "nsx-mgr-01", "nsx-mgr-02", "nsx-mgr-03", "ad-dc01", "ad-dc02", "veeam-br01", "veeam-proxy-01", "veeam-proxy-02",
              "vrli-01", "vrops-01", "jump-01", "jump-02", "pki-root", "pki-sub01", "syslog-01", "ntp-01", "dns-01", "dns-02", "wsus-01",
              "sccm-01", "sccm-db01", "monitor-01", "backup-repo-01", "kms-01"]
photon = ("VMware Photon OS (64-bit)", "VMware Photon OS 3.0", 0, "lin")
for n in mgmt_names:
    make_vm(n, "Mgmt-Cluster", R.choice(hosts_by_cluster["Mgmt-Cluster"]), os_entry=photon if n.startswith(("vcsa", "nsx", "vr")) else None,
            power="poweredOn")
for i in range(8):
    make_vm(f"DMZ-WEB-{i + 1:02d}", "", hosts_by_cluster[""][0], power="poweredOn")
for n, o in [("TPL-WS2022", OSES[1]), ("TPL-WS2019", OSES[0]), ("TPL-RHEL9", OSES[6]), ("TPL-UBU2204", OSES[8]), ("TPL-WS2012R2", OSES[3]), ("TPL-CENTOS7", OSES[7])]:
    make_vm(n, "Prod-Cluster", R.choice(hosts_by_cluster["Prod-Cluster"]), os_entry=o, template=True, cpus=2, mem_gb=4)

# Deliberate specifics
big = make_vm("PRD-SQL-BIG01", "Prod-Cluster", hosts_by_cluster["Prod-Cluster"][2], os_entry=OSES[0], cpus=48, mem_gb=512, power="poweredOn")
wide = make_vm("PRD-ANALYTICS01", "Prod-Cluster", hosts_by_cluster["Prod-Cluster"][1], os_entry=OSES[5], cpus=80, mem_gb=256, power="poweredOn")
monster = make_vm("DEV-BUILD-MONSTER", "Dev-Cluster", hosts_by_cluster["Dev-Cluster"][0], os_entry=OSES[8], cpus=40, mem_gb=128, power="poweredOn")
mismatch = make_vm("PRD-APP-LEGACYOS", "Prod-Cluster", hosts_by_cluster["Prod-Cluster"][0],
                   os_entry=("Microsoft Windows Server 2016 (64-bit)", "Microsoft Windows Server 2019 Datacenter", 0, "win"), power="poweredOn")

# ---------------------------------------------------------------- per-VM details
for vm in vms:
    fam = vm["fam"]
    ndisks = R.choices([1, 2, 3, 4], [35, 40, 18, 7])[0]
    dslist = cluster_ds(vm["cluster"])
    home = R.choice(dslist)
    if vm["cluster"] == "Prod-Cluster" and R.random() < 0.012:
        home = vm["host"]["name"].split(".")[0] + "-local"  # VM on local storage in a multi-host cluster
    vm["home"] = home
    ctrl = R.choices(["VMware paravirtual SCSI", "LSI Logic SAS", "LSI Logic", "BusLogic"], [42, 50, 7, 1])[0]
    if "2008" in vm["cfg"]:
        ctrl = R.choice(["LSI Logic SAS", "BusLogic"])
    for d in range(ndisks):
        cap = (R.choice([40, 60, 80, 100]) if d == 0 else R.choice([50, 100, 200, 250, 500, 750, 1000, 2000])) * MIB_GB
        ds = home if d == 0 or R.random() < 0.7 else R.choice(dslist)
        thin = R.random() < 0.72
        mode = "persistent"
        if R.random() < 0.01:
            mode = "independent_persistent"
        vm["disks"].append(dict(label=f"Hard disk {d + 1}", cap=cap, thin=thin, eager=(not thin and R.random() < 0.3), mode=mode,
                                ctrl=ctrl, ds=ds, raw=False, bus="noSharing", sharing="sharingNone",
                                path=f"[{ds}] {vm['name']}/{vm['name']}{'' if d == 0 else '_' + str(d)}.vmdk"))
    # partitions
    for d, disk in enumerate(vm["disks"]):
        if vm["power"] != "poweredOn" or vm["template"]:
            break
        label = (["C:\\", "D:\\", "E:\\", "F:\\"][d] if fam == "win" else ["/", "/var", "/data", "/opt"][d])
        free = R.choices([R.uniform(1, 4.9), R.uniform(5, 9.9), R.uniform(10, 30), R.uniform(30, 85)], [3, 6, 30, 61])[0]
        capm = disk["cap"] - (500 if fam == "win" else 1024)
        vm.setdefault("parts", []).append(dict(disk=label, cap=capm, free=capm * free / 100))
        if fam == "lin" and d == 0:
            vm["parts"].append(dict(disk="/boot", cap=1014, free=1014 * R.uniform(0.3, 0.8)))
    # NICs
    nets = NETS[vm["cluster"]]
    for n in range(R.choices([1, 2], [85, 15])[0]):
        pg, prefix = R.choice(nets)
        if pg == "PG-Nested-Lab-250" and R.random() < 0.7:
            pg, prefix = nets[0]
        adapter = R.choices(["Vmxnet3", "E1000e", "E1000"], [86, 10, 4])[0]
        connected = vm["power"] == "poweredOn" and not (n == 1 and R.random() < 0.3)
        vm["nics"].append(dict(label=f"Network adapter {n + 1}", adapter=adapter, pg=pg, connected=connected, mac=next_mac(),
                               ip=next_ip(prefix) if vm["power"] == "poweredOn" and not vm["template"] else ""))
    vm["cbt"] = R.random() < 0.85
    # tools
    if vm["power"] == "poweredOn":
        vm["tools"] = R.choices(["toolsOk", "toolsOld", "toolsNotRunning", "toolsNotInstalled"], [75, 18, 4, 3])[0]
    else:
        vm["tools"] = "toolsNotRunning"
    if vm["name"].startswith(("vcsa", "nsx", "vr")):
        vm["tools"] = "toolsOk"
    vm["hb"] = "green" if vm["tools"] in ("toolsOk", "toolsOld") and vm["power"] == "poweredOn" else "gray"
    vm["cpu_limit"] = -1
    vm["mem_limit"] = -1
    vm["balloon"] = 0
    vm["swap"] = 0
    vm["hotadd"] = R.random() < 0.4
    vm["cds"] = [dict(node="CD/DVD drive 1", connected=False, type="Client Device")]

# Special cases
big["disks"].append(dict(label="Hard disk 9", cap=2048 * MIB_GB, thin=False, eager=True, mode="independent_persistent", ctrl="VMware paravirtual SCSI",
                         ds="prod-vmfs-03", raw=True, bus="physicalSharing", sharing="sharingMultiWriter", path="[prod-vmfs-03] PRD-SQL-BIG01/PRD-SQL-BIG01_rdm.vmdk"))
big["hotadd"] = True
wide["hotadd"] = True
vms[3]["hb"] = "red"
vms[7]["cpu_limit"] = 2000
vms[19]["cpu_limit"] = 4000
vms[42]["mem_limit"] = 4096
prod03 = hosts_by_cluster["Prod-Cluster"][2]
for vm in prod03["vms"][:5]:
    if vm["power"] == "poweredOn":
        vm["balloon"] = R.choice([512, 1024, 2048])
        vm["swap"] = R.choice([0, 256])
for vm in R.sample([v for v in vms if v["power"] == "poweredOn" and not v["template"]], 6):
    vm["cds"][0].update(connected=True, type="ISO [iso-library] ISO/SW_DVD9_Win_Server_STD_CORE_2019.iso")
mgmt_vms = hosts_by_cluster["Mgmt-Cluster"][0]["vms"] + hosts_by_cluster["Mgmt-Cluster"][1]["vms"]
consol = next(v for v in vms if v["power"] == "poweredOn" and v["cluster"] == "Prod-Cluster" and not v["template"])
consol["consolidate"] = True
# duplicate IPs / MAC
on_prod = [v for v in vms if v["power"] == "poweredOn" and v["cluster"] == "Prod-Cluster" and v["nics"] and v["nics"][0]["ip"]]
on_prod[10]["nics"][0]["ip"] = on_prod[11]["nics"][0]["ip"]
on_prod[30]["nics"][0]["ip"] = on_prod[31]["nics"][0]["ip"]
on_prod[50]["nics"][0]["mac"] = on_prod[51]["nics"][0]["mac"]
dup_name = make_vm("PRD-APP-001", "Prod-Cluster", hosts_by_cluster["Prod-Cluster"][4], power="poweredOff")
for key in ("disks", "nics"):
    dup_name[key] = []
dup_name.update(home="prod-vmfs-01", cbt=False, tools="toolsNotRunning", hb="gray", cpu_limit=-1, mem_limit=-1, balloon=0, swap=0, hotadd=False,
                cds=[dict(node="CD/DVD drive 1", connected=False, type="Client Device")])
dup_name["disks"].append(dict(label="Hard disk 1", cap=60 * MIB_GB, thin=True, eager=False, mode="persistent", ctrl="LSI Logic SAS", ds="prod-vmfs-01",
                              raw=False, bus="noSharing", sharing="sharingNone", path="[prod-vmfs-01] PRD-APP-001_1/PRD-APP-001.vmdk"))
usb_vm = hosts_by_cluster[""][0]["vms"][0]

# Snapshots
snap_candidates = R.sample([v for v in vms if not v["template"]], 18)
for i, vm in enumerate(snap_candidates):
    age = [0.3, 0.6, 2, 3, 5, 9, 12, 16, 21, 34, 45, 62, 88, 120, 150, 210, 400, 1.2][i]
    for s in range(1 if i % 4 else 2):
        name = "VEEAM BACKUP TEMPORARY SNAPSHOT" if age < 1 else R.choice(["Before patching", "pre-upgrade", "Snapshot 1", "CHG0041337 rollback", "test"])
        vm["snaps"].append(dict(name=name, desc="" if age < 1 else "Created by ops", date=days_ago(age + s * 3, jitter_hours=False),
                                size=R.choice([800, 4000, 12000, 25000, 60000, 110000]) + R.random()))

# ---------------------------------------------------------------- datastore usage from VMs
for vm in vms:
    # RVTools' "# VMs total" counts exclude templates
    for d in vm["disks"]:
        ds = ds_by_name[d["ds"]]
        if not vm["template"]:
            ds["vms"].add(vm["name"] + vm["id"])
        ds["prov"] += d["cap"]
        used = d["cap"] if not d["thin"] else d["cap"] * R.uniform(0.25, 0.7)
        d["used"] = used
        ds["used"] += used
    if not vm["template"]:
        ds_by_name[vm["home"]]["vms"].add(vm["name"] + vm["id"])
for ds in datastores:
    ds["used"] += ds["cap"] * 0.01
targets = {"prod-vmfs-04": 0.935, "prod-vmfs-02": 0.83, "dev-nfs-02": 0.86, "esx-dmz01-local": 0.64}
for n, pct in targets.items():
    ds_by_name[n]["used"] = ds_by_name[n]["cap"] * pct
ds_by_name["prod-vmfs-05"]["prov"] = ds_by_name["prod-vmfs-05"]["cap"] * 1.62
for ds in datastores:
    ds["used"] = min(ds["used"], ds["cap"] * 0.97)
    if ds["prov"] < ds["used"]:
        ds["prov"] = ds["used"] * 1.05

# ---------------------------------------------------------------- write VM-level tabs


def vm_tail(vm):
    return {"Annotation": "Owner: app-team" if R.random() < 0.3 else None, "Datacenter": vm["dc"], "Cluster": vm["cluster"] or None,
            "Host": vm["host"]["name"], "Folder": ("Templates" if vm["template"] else vm["cluster"].split("-")[0] or "DMZ"),
            "OS according to the configuration file": vm["cfg"], "OS according to the VMware Tools": vm["tools_os"] if vm["power"] == "poweredOn" else None,
            "VM ID": vm["id"], "VM UUID": vm["uuid"], "VI SDK Server": VC, "VI SDK UUID": VCUUID, "VMRef": vm["id"]}


for vm in vms:
    on = vm["power"] == "poweredOn"
    prov = sum(d["cap"] for d in vm["disks"]) + vm["mem"] + 300
    used = sum(d.get("used", d["cap"]) for d in vm["disks"]) + (vm["mem"] if on else 0)
    base = {"VM": vm["name"], "Powerstate": vm["power"], "Template": tf(vm["template"]), "SRM Placeholder": "False"}
    info = dict(base)
    info.update({"Config status": "green", "DNS Name": (vm["name"].lower() + ".corp.example") if on else None, "Connection state": "connected",
                 "Guest state": "running" if on and vm["tools"] in ("toolsOk", "toolsOld") else "notRunning", "Heartbeat": vm["hb"],
                 "Consolidation Needed": tf(vm.get("consolidate", False)), "PowerOn": days_ago(R.randint(1, 90)) if on else None,
                 "Creation date": vm["created"], "CPUs": vm["cpus"], "Overall Cpu Readiness": (R.choice([0, 0, 0, 1, 2, 7]) if on else None),
                 "Memory": vm["mem"], "Active Memory": int(vm["mem"] * R.uniform(0.05, 0.4)) if on else 0, "NICs": len(vm["nics"]),
                 "Disks": len(vm["disks"]), "Total disk capacity MiB": sum(d["cap"] for d in vm["disks"]), "Latency Sensitivity": "normal",
                 "EnableUUID": "True", "CBT": "TRUE" if vm["cbt"] else None, "Primary IP Address": vm["nics"][0]["ip"] if vm["nics"] else None,
                 "Resource pool": f"/{vm['dc']}/host/{vm['cluster'] or vm['host']['name']}/Resources", "Folder": "Templates" if vm["template"] else "VMs",
                 "FT State": "notConfigured", "Provisioned MiB": int(prov), "In Use MiB": int(used), "Unshared MiB": int(used),
                 "HA Restart Priority": "clusterRestartPriority", "HA Isolation Response": "none", "HA VM Monitoring": "vmMonitoringDisabled",
                 "Firmware": "efi" if vm["hw"] >= 14 and R.random() < 0.7 else "bios", "HW version": vm["hw"], "HW upgrade status": "none",
                 "HW upgrade policy": "never", "Path": f"[{vm['home']}] {vm['name']}/{vm['name']}.vmx", "VI SDK Server type": "VMware vCenter Server",
                 "VI SDK API Version": "8.0.2.0", "Num Monitors": 1, "Video Ram KiB": 8192})
    info["EFI Secure boot"] = tf(info["Firmware"] == "efi" and R.random() < 0.5)
    for n, nic in enumerate(vm["nics"][:8]):
        info[f"Network #{n + 1}"] = nic["pg"]
    info.update(vm_tail(vm))
    rows["vInfo"].append(info)

    cpu = dict(base)
    sockets = 2 if vm["cpus"] >= 8 and vm["cpus"] % 2 == 0 else 1
    cpu.update({"CPUs": vm["cpus"], "Sockets": sockets, "Cores p/s": vm["cpus"] // sockets, "Max": vm["cpus"] * 2000, "Overall": int(vm["cpus"] * 2000 * R.uniform(0.02, 0.3)) if on else 0,
                "Level": "normal", "Shares": vm["cpus"] * 1000, "Reservation": 0, "Entitlement": 0, "DRS Entitlement": 0, "Limit": vm["cpu_limit"],
                "Hot Add": tf(vm["hotadd"]), "Hot Remove": "False", "Numa Hotadd Exposed": "False"})
    cpu.update(vm_tail(vm))
    rows["vCPU"].append(cpu)

    mem = dict(base)
    mem.update({"Size MiB": vm["mem"], "Memory Reservation Locked To Max": "False", "Overhead": 60, "Max": vm["mem"], "Consumed": int(vm["mem"] * 0.8) if on else 0,
                "Consumed Overhead": 40, "Private": int(vm["mem"] * 0.7) if on else 0, "Shared": 0, "Swapped": vm["swap"], "Ballooned": vm["balloon"],
                "Active": int(vm["mem"] * 0.2) if on else 0, "Entitlement": 0, "DRS Entitlement": 0, "Level": "normal", "Shares": vm["mem"] * 10,
                "Reservation": 0, "Limit": vm["mem_limit"], "Hot Add": tf(vm["hotadd"])})
    mem.update(vm_tail(vm))
    rows["vMemory"].append(mem)

    for k, d in enumerate(vm["disks"]):
        row = dict(base)
        row.update({"Disk": d["label"], "Disk Key": 2000 + k, "Disk UUID": f"6000C29{R.getrandbits(100):025x}", "Disk Path": d["path"], "Capacity MiB": d["cap"],
                    "Raw": tf(d["raw"]), "Disk Mode": d["mode"], "Sharing mode": d["sharing"], "Thin": tf(d["thin"]), "Eagerly Scrub": tf(d["eager"]),
                    "Split": "False", "Write Through": "False", "Level": "normal", "Shares": 1000, "Reservation": 0, "Limit": -1, "Controller": d["ctrl"],
                    "Label": d["label"], "SCSI Unit #": f"0:{k}", "Unit #": k, "Shared Bus": d["bus"], "Path": d["path"],
                    "Raw LUN ID": "naa.600a098038303053453f463045727a41" if d["raw"] else None, "Raw Comp. Mode": "physicalMode" if d["raw"] else None,
                    "Internal Sort Column": k})
        row.update(vm_tail(vm))
        rows["vDisk"].append(row)

    for k, p in enumerate(vm.get("parts", [])):
        row = dict(base)
        row.update({"Disk Key": 2000 + k, "Disk": p["disk"], "Capacity MiB": int(p["cap"]), "Consumed MiB": int(p["cap"] - p["free"]), "Free MiB": int(p["free"]),
                    "Free %": int(round(p["free"] / p["cap"] * 100)), "Internal Sort Column": k})
        row.update(vm_tail(vm))
        rows["vPartition"].append(row)

    for k, nic in enumerate(vm["nics"]):
        row = dict(base)
        row.update({"NIC label": nic["label"], "Adapter": nic["adapter"], "Network": nic["pg"],
                    "Switch": {"DMZ-Net": "vSwitch1", "PG-Mgmt-VMs-15": "dvs-mgmt"}.get(nic["pg"], "dvs-prod"),
                    "Connected": tf(nic["connected"]), "Starts Connected": tf(nic["connected"] or vm["power"] != "poweredOn"), "Mac Address": nic["mac"],
                    "Type": "assigned", "IPv4 Address": nic["ip"] or None, "Direct Path IO": "False", "Internal Sort Column": k})
        row.update(vm_tail(vm))
        rows["vNetwork"].append(row)

    for cd in vm["cds"]:
        row = dict(base)
        row.update({"Device Node": cd["node"], "Connected": tf(cd["connected"]), "Starts Connected": tf(cd["connected"]), "Device Type": cd["type"]})
        row.update(vm_tail(vm))
        rows["vCD"].append(row)

    for s in vm["snaps"]:
        row = {"VM": vm["name"], "Powerstate": vm["power"], "Name": s["name"], "Description": s["desc"], "Date / time": s["date"],
               "Filename": f"[{vm['home']}] {vm['name']}/{vm['name']}-Snapshot1.vmsn", "Size MiB (vmsn)": 30, "Size MiB (total)": s["size"],
               "Quiesced": "False", "State": "poweredOff"}
        row.update(vm_tail(vm))
        rows["vSnapshot"].append(row)

    tools_ver = {"toolsOk": 12352, "toolsOld": R.choice([10346, 11269, 11333]), "toolsNotRunning": 12320, "toolsNotInstalled": 0}[vm["tools"]]
    row = dict(base)
    row.update({"VM Version": vm["hw"], "Tools": vm["tools"], "Tools Version": tools_ver, "Required Version": 12352,
                "Upgradeable": "Yes" if vm["tools"] == "toolsOld" else "No", "Upgrade Policy": R.choice(["manual", "upgradeAtPowerCycle"]),
                "Sync time": "False", "App status": "appStatusGray", "Heartbeat status": "appStatusGray", "Kernel Crash state": None,
                "Operation Ready": tf(vm["power"] == "poweredOn"), "State change support": "True", "Interactive Guest": "False"})
    row.update(vm_tail(vm))
    rows["vTools"].append(row)

usb = {"VM": usb_vm["name"], "Powerstate": usb_vm["power"], "Template": "False", "SRM Placeholder": "False", "Device Node": "USB 1",
       "Device Type": "SafeNet Token JC", "Connected": "True", "Family": "other", "Speed": "full", "EHCI enabled": "True", "Auto connect": "True",
       "Bus number": 1, "Unit number": 1}
usb.update(vm_tail(usb_vm))
rows["vUSB"].append(usb)

# ---------------------------------------------------------------- host-level tabs
for h in hosts:
    on = [v for v in h["vms"] if v["power"] == "poweredOn" and not v["template"]]
    cores = h["sockets"] * h["cps"]
    cl = h["cluster"]
    is_dmz = "dmz" in h["name"]
    is_mgmt = "mgmt" in h["name"]
    rows["vHost"].append({
        "Host": h["name"], "Datacenter": h["dc"], "Cluster": cl or None, "Config status": "yellow" if is_dmz else "green",
        "in Maintenance Mode": tf(h["name"] == "esx-dev03.corp.example"), "in Quarantine Mode": "False", "CPU Model": h["cpu"], "Speed": h["speed"],
        "HT Available": "True", "HT Active": tf(not is_dmz), "# CPU": h["sockets"], "Cores per CPU": h["cps"], "# Cores": cores,
        "CPU usage %": h["cpu_pct"], "# Memory": h["mem"], "Memory usage %": h["mem_pct"], "Console": 0, "# NICs": 1 if is_dmz else (4 if "prod" in h["name"] else 2),
        "# HBAs": 2 if "prod" in h["name"] else 1, "# VMs total": len([v for v in h["vms"] if not v["template"]]), "# VMs": len(on), "VMs per Core": round(len(on) / cores, 2),
        "# vCPUs": sum(v["cpus"] for v in on), "vCPUs per Core": round(sum(v["cpus"] for v in on) / cores, 2), "vRAM": sum(v["mem"] for v in on),
        "VM Used memory": int(h["mem"] * h["mem_pct"] / 100 * 0.9), "VM Memory Swapped": 0, "VM Memory Ballooned": 0,
        "VMotion support": "True", "Storage VMotion support": "True", "Current EVC": None, "Max EVC": "intel-icelake" if "6338" in h["cpu"] else "intel-skylake",
        "Assigned License(s)": "VMware vSphere 8 Enterprise Plus", "ATS Heartbeat": "True", "ATS Locking": "True",
        "Current CPU power man. policy": "Balanced", "Supported CPU power man.": "Static, Dynamic", "Host Power Policy": "Balanced",
        "ESX Version": h["esx"], "Boot time": days_ago(520 if is_mgmt else R.randint(20, 160)), "DNS Servers": "10.0.15.53, 10.0.15.54",
        "DHCP": "False", "Domain": "corp.example", "DNS Search Order": "corp.example",
        "NTP Server(s)": None if is_dmz else "ntp1.corp.example, ntp2.corp.example", "NTPD running": tf(not is_dmz), "Time Zone": "UTC",
        "Time Zone Name": "UTC", "GMT Offset": 0, "Vendor": h["vendor"], "Model": h["model"], "Serial number": f"SN{R.getrandbits(32):08X}",
        "Service tag": None, "BIOS Vendor": h["vendor"], "BIOS Version": "2.19.1", "BIOS Date": dt.datetime(2024, 3, 1),
        "Certificate Issuer": "O=VMware, CN=CA", "Certificate Start Date": dt.datetime(2024, 1, 10),
        "Certificate Expiry Date": EXPORT + dt.timedelta(days=41) if h["name"] == "esx-mgmt01.corp.example" else dt.datetime(2029, 1, 10),
        "Certificate Status": "good", "Object ID": f"host-{100 + h['idx']}", "UUID": f"4c4c4544-{R.getrandbits(64):016x}", "VI SDK Server": VC, "VI SDK UUID": VCUUID})

    nnics = 1 if is_dmz else (4 if "prod" in h["name"] else 2)
    for n in range(nnics):
        sw = "vSwitch0" if n == 0 and not is_dmz else ("vSwitch1" if is_dmz else ("dvs-mgmt" if is_mgmt else "dvs-prod"))
        speed = 1000 if is_dmz else (25000 if "prod" in h["name"] else 10000)
        if h["name"] == "esx-dev02.corp.example" and n == 1:
            speed = 0
        rows["vNIC"].append({"Host": h["name"], "Datacenter": h["dc"], "Cluster": cl or None, "Network Device": f"vmnic{n}", "Driver": "i40en" if speed != 25000 else "bnxtnet",
                             "Speed": speed, "Duplex": "Full" if speed else None, "MAC": f"b4:96:91:{h['idx']:02x}:00:{n:02x}", "Switch": sw,
                             "Uplink port": f"uplink{n + 1}", "PCI": f"0000:3b:00.{n}", "WakeOn": "False", "VI SDK Server": VC, "VI SDK UUID": VCUUID})
    for n in range(2 if "prod" in h["name"] else 1):
        rows["vHBA"].append({"Host": h["name"], "Datacenter": h["dc"], "Cluster": cl or None, "Device": f"vmhba{n + 1}",
                             "Type": "Fibre Channel" if "prod" in h["name"] else "Block SCSI", "Status": "online" if "prod" in h["name"] else "unknown",
                             "Bus": 59, "Pci": f"0000:5e:00.{n}", "Driver": "qlnativefc" if "prod" in h["name"] else "lsi_mr3",
                             "Model": "QLogic QLE2772 32Gb FC" if "prod" in h["name"] else "Avago MegaRAID SAS", "WWN": f"20:00:00:24:ff:{h['idx']:02x}:00:{n:02x}" if "prod" in h["name"] else None,
                             "VI SDK Server": VC, "VI SDK UUID": VCUUID})
    std_sw = "vSwitch1" if is_dmz else "vSwitch0"
    rows["vSwitch"].append({"Host": h["name"], "Datacenter": h["dc"], "Cluster": cl or None, "Switch": std_sw, "# Ports": 2560, "Free Ports": 2540,
                            "Promiscuous Mode": "False", "Mac Changes": tf(is_dmz), "Forged Transmits": tf(is_dmz), "Traffic Shaping": "False",
                            "Policy": "loadbalance_srcid", "Reverse Policy": "True", "Notify Switch": "True", "Rolling Order": "False", "Offload": "True",
                            "TSO": "True", "Zero Copy Xmit": "True", "MTU": 1500, "VI SDK Server": VC, "VI SDK UUID": VCUUID})
    pgs = [("Management Network", 10)] + ([("DMZ-Net", 300), ("VM Network", 0)] if is_dmz else []) + ([("VM Network", 0)] if is_mgmt else [])
    for pg, vlan in pgs:
        rows["vPort"].append({"Host": h["name"], "Datacenter": h["dc"], "Cluster": cl or None, "Port Group": pg, "Switch": std_sw, "VLAN": vlan,
                              "Promiscuous Mode": False, "Mac Changes": pg == "DMZ-Net", "Forged Transmits": pg == "DMZ-Net", "Traffic Shaping": False,
                              "Policy": "loadbalance_srcid", "Reverse Policy": True, "Notify Switch": True, "Rolling Order": False, "Offload": True,
                              "TSO": True, "Zero Copy Xmit": True, "VI SDK Server": VC, "VI SDK UUID": VCUUID})
    for k, (pg, ip) in enumerate([("Management Network", f"10.0.10.{11 + h['idx']}"), ("PG-vMotion-20" if not is_dmz else "Management Network", f"10.0.20.{11 + h['idx']}")]):
        if is_dmz and k == 1:
            break
        rows["vSC_VMK"].append({"Host": h["name"], "Datacenter": h["dc"], "Cluster": cl or None, "Port Group": pg, "Device": f"vmk{k}",
                                "Mac Address": f"00:50:56:6{k}:{h['idx']:02x}:01", "DHCP": "False", "IP Address": ip, "Subnet mask": "255.255.255.0",
                                "Gateway": "10.0.10.1", "MTU": 9000 if k == 1 else 1500, "VI SDK Server": VC, "VI SDK UUID": VCUUID})
    if "prod" in h["name"]:
        for ds in [d for d in datastores if d["name"].startswith("prod-vmfs")]:
            npaths = 4
            states = ["active", "active", "standby", "standby"]
            if h["name"] == "esx-prod06.corp.example" and ds["name"] == "prod-vmfs-05":
                npaths, states = 1, ["active"]
            if h["name"] == "esx-prod02.corp.example" and ds["name"] == "prod-vmfs-02":
                states = ["active", "dead", "standby", "dead"]
            row = {"Host": h["name"], "Cluster": cl, "Datacenter": h["dc"], "Datastore": ds["name"], "Disk": f"naa.600a0980383030{ds['name'][-2:]}",
                   "Display name": f"NETAPP Fibre Channel Disk (naa.600a0980383030{ds['name'][-2:]})", "Policy": "VMW_PSP_RR", "Oper. State": "ok",
                   "vStorage": "supported", "Queue depth": 64, "Vendor": "NETAPP", "Model": "LUN C-Mode", "Revision": "9800", "Level": "SPC-4",
                   "VI SDK Server": VC, "VI SDK UUID": VCUUID}
            for p in range(npaths):
                row[f"Path {p + 1}"] = f"vmhba{p % 2 + 1}:C0:T{p // 2}:L{ds['name'][-1]}"
                row[f"Path {p + 1} state"] = states[p]
            rows["vMultiPath"].append(row)

for c in CLUSTERS:
    if not c["name"]:
        continue
    hs = hosts_by_cluster[c["name"]]
    cores = sum(h["sockets"] * h["cps"] for h in hs)
    rows["vCluster"].append({"Name": c["name"], "Config status": "green", "OverallStatus": "yellow" if c["name"] == "Mgmt-Cluster" else "green",
                             "NumHosts": len(hs), "numEffectiveHosts": len(hs) - (1 if c["name"] == "Dev-Cluster" else 0),
                             "TotalCpu": sum(h["sockets"] * h["cps"] * h["speed"] for h in hs), "NumCpuCores": cores, "NumCpuThreads": cores * 2,
                             "Effective Cpu": int(sum(h["sockets"] * h["cps"] * h["speed"] for h in hs) * 0.92), "TotalMemory": sum(h["mem"] for h in hs),
                             "Effective Memory": int(sum(h["mem"] for h in hs) * 0.86), "Num VMotions": R.randint(200, 9000), "HA enabled": tf(c["ha"]),
                             "Failover Level": 1, "AdmissionControlEnabled": tf(c["ac"]), "Host monitoring": "enabled", "Isolation Response": "none",
                             "Restart Priority": "medium", "VM Monitoring": "vmMonitoringDisabled", "DRS enabled": tf(c["drs"]),
                             "DRS default VM behavior": "fullyAutomated", "DRS vmotion rate": 3, "DPM enabled": "False", "DPM default behavior": "manual",
                             "Object ID": f"domain-c{10 + CLUSTERS.index(c)}", "VI SDK Server": VC, "VI SDK UUID": VCUUID})

for ds in datastores:
    free = ds["cap"] - ds["used"]
    dc = ds["hosts"][0]["dc"]
    rows["vDatastore"].append({"Name": ds["name"], "Config status": "green", "Address": "nfs01.corp.example:/vol/" + ds["name"] if ds["type"] == "NFS" else None,
                               "Accessible": "True", "Type": ds["type"], "# VMs total": len(ds["vms"]), "# VMs": len(ds["vms"]),
                               "Capacity MiB": ds["cap"], "Provisioned MiB": int(ds["prov"]), "In Use MiB": int(ds["used"]), "Free MiB": int(free),
                               "Free %": int(round(free / ds["cap"] * 100)), "SIOC enabled": "False", "SIOC Threshold": 30, "# Hosts": len(ds["hosts"]),
                               "Hosts": ", ".join(h["name"] for h in ds["hosts"]), "Cluster name": None, "Block size": 1 if ds["type"] == "VMFS" else None,
                               "# Extents": 1 if ds["type"] == "VMFS" else None, "Major Version": ds["major"] if ds["type"] == "VMFS" else None,
                               "Version": f"{ds['major']}.82" if ds["type"] == "VMFS" else None, "URL": ds["url"], "Object ID": f"datastore-{200 + datastores.index(ds)}",
                               "VI SDK Server": VC, "VI SDK UUID": VCUUID})

rows["dvSwitch"] += [
    {"Switch": "dvs-prod", "Datacenter": "DC-East", "Name": "dvs-prod", "Vendor": "VMware, Inc.", "Version": "8.0.0", "Created": dt.datetime(2023, 5, 2),
     "Host members": ", ".join(h["name"] for h in hosts_by_cluster["Prod-Cluster"] + hosts_by_cluster["Dev-Cluster"]), "Max Ports": 2147483647,
     "# Ports": 612, "# VMs": 330, "Max MTU": 9000, "LACP Mode": None, "CDP Type": "cdp", "CDP Operation": "listen", "VI SDK Server": VC, "VI SDK UUID": VCUUID},
    {"Switch": "dvs-mgmt", "Datacenter": "DC-West", "Name": "dvs-mgmt", "Vendor": "VMware, Inc.", "Version": "6.6.0", "Created": dt.datetime(2019, 2, 14),
     "Host members": ", ".join(h["name"] for h in hosts_by_cluster["Mgmt-Cluster"]), "Max Ports": 2147483647, "# Ports": 96, "# VMs": 25,
     "Max MTU": 1500, "LACP Mode": None, "CDP Type": "cdp", "CDP Operation": "listen", "VI SDK Server": VC, "VI SDK UUID": VCUUID},
]
for port, sw, vlan, promisc in [("PG-App-100", "dvs-prod", "100", False), ("PG-DB-110", "dvs-prod", "110", False), ("PG-Web-120", "dvs-prod", "120", False),
                                ("PG-Dev-200", "dvs-prod", "200", False), ("PG-Nested-Lab-250", "dvs-prod", "250", True), ("PG-vMotion-20", "dvs-prod", "20", False),
                                ("PG-Legacy-199", "dvs-prod", "199", False), ("dvs-prod-DVUplinks-11", "dvs-prod", "0-4094", False),
                                ("PG-Mgmt-VMs-15", "dvs-mgmt", "15", False), ("dvs-mgmt-DVUplinks-31", "dvs-mgmt", "0-4094", False)]:
    rows["dvPort"].append({"Port": port, "Switch": sw, "Type": "earlyBinding", "# Ports": 128, "VLAN": vlan, "Blocked": "False",
                           "Allow Promiscuous": tf(promisc), "Mac Changes": tf(promisc), "Forged Transmits": tf(promisc), "Policy": "loadbalance_srcid",
                           "Active Uplink": "uplink1, uplink2", "Standby Uplink": None, "Reverse Policy": "True", "Notify Switch": "True",
                           "Rolling Order": "False", "Check Beacon": "False", "Object ID": f"dvportgroup-{300 + len(rows['dvPort'])}", "VI SDK Server": VC, "VI SDK UUID": VCUUID})

rows["vSource"].append({"Name": "VMware vCenter Server", "OS type": "linux-x64", "API type": "VirtualCenter", "API version": "8.0.2.0", "Version": "8.0.2",
                        "Patch level": "00300", "Build": "24321653", "Fullname": "VMware vCenter Server 8.0.2 build-24321653", "Product name": "VMware VirtualCenter Server",
                        "Product version": "8.0", "Product line": "vpx", "Vendor": "VMware, Inc.", "VI SDK Server": VC, "VI SDK UUID": VCUUID})
rows["vLicense"] += [
    {"Name": "VMware vCenter Server 8 Standard", "Key": "0A0AA-BBBBB-CCCCC-DDDDD-11111", "Cost Unit": "Server", "Total": 1, "Used": 1, "Expiration Date": "Never",
     "Features": "vCenter", "VI SDK Server": VC, "VI SDK UUID": VCUUID},
    {"Name": "VMware vSphere 8 Enterprise Plus", "Key": "1B1BB-CCCCC-DDDDD-EEEEE-22222", "Cost Unit": "CPU (1-32 cores)", "Total": 20, "Used": 24,
     "Expiration Date": "Never", "Features": "DRS, HA, vMotion", "VI SDK Server": VC, "VI SDK UUID": VCUUID},
    {"Name": "VMware vSAN Advanced", "Key": "2C2CC-DDDDD-EEEEE-FFFFF-33333", "Cost Unit": "CPU (1-32 cores)", "Total": 4, "Used": 4,
     "Expiration Date": EXPORT + dt.timedelta(days=45), "Features": "vSAN", "VI SDK Server": VC, "VI SDK UUID": VCUUID},
]
rows["vRP"] += [
    {"Resource Pool name": "Resources", "Resource Pool path": f"/{c['dc']}/host/{c['name']}/Resources", "Status": "green",
     "# VMs total": len([v for v in vms if v["cluster"] == c["name"]]), "# VMs": len([v for v in vms if v["cluster"] == c["name"] and v["power"] == "poweredOn"]),
     "CPU limit": -1, "CPU reservation": 0, "Mem limit": -1, "Mem reservation": 0, "VI SDK Server": VC, "VI SDK UUID": VCUUID}
    for c in CLUSTERS if c["name"]
]
for vm in vms:
    for s in vm["snaps"]:
        rows["vHealth"].append({"Name": vm["name"], "Message": f"VM has an active snapshot! {s['name']} created on {s['date']:%m/%d/%Y %H:%M:%S}", "Message type": "Snapshot",
                                "VI SDK Server": VC, "VI SDK UUID": VCUUID})
    if vm["tools"] != "toolsOk" and vm["power"] == "poweredOn":
        rows["vHealth"].append({"Name": vm["name"], "Message": "VMware tools are out of date, not running or not installed!", "Message type": "VM Tools",
                                "VI SDK Server": VC, "VI SDK UUID": VCUUID})
for p in ["[prod-vmfs-02] OLD-FS-07/OLD-FS-07.vmdk", "[prod-vmfs-04] PRD-APP-DECOM3/PRD-APP-DECOM3_1.vmdk", "[dev-nfs-01] test-clone/test-clone-flat.vmdk"]:
    rows["vHealth"].append({"Name": p, "Message": "Possibly a Zombie vmdk file! Please check.", "Message type": "Zombie", "VI SDK Server": VC, "VI SDK UUID": VCUUID})
for vm in vms[60:63]:
    rows["vHealth"].append({"Name": vm["name"], "Message": f"Inconsistent Foldername! VMname = {vm['name']}  Foldername = {vm['name']}_old", "Message type": "Foldername",
                            "VI SDK Server": VC, "VI SDK UUID": VCUUID})
for vm in vms[80:85]:
    rows["vHealth"].append({"Name": vm["name"], "Message": "In-Memory VM performance improvement possible! Please check documentation", "Message type": "Performance tip",
                            "VI SDK Server": VC, "VI SDK UUID": VCUUID})
rows["vHealth"].append({"Name": "esx-dmz01.corp.example", "Message": "NTP Server value is null!", "Message type": "Host config", "VI SDK Server": VC, "VI SDK UUID": VCUUID})
rows["vMetaData"].append({"RVTools major version": 4.7, "RVTools version": "4.7.1.4", "xlsx creation datetime": EXPORT, "Server": VC})

# ---------------------------------------------------------------- write outputs
os.makedirs(OUT, exist_ok=True)
stamp = f"{EXPORT:%Y-%m-%d_%H.%M.%S}"
xlsx_path = os.path.join(OUT, f"RVTools_export_all_{stamp}.xlsx")
wb = Workbook()
wb.remove(wb.active)
for tab, headers in HEADERS.items():
    ws = wb.create_sheet(tab)
    ws.append(headers)
    for r in rows[tab]:
        ws.append([r.get(h) for h in headers])
wb.save(xlsx_path)

csv_dir = os.path.join(OUT, f"RVTools_export_all_{stamp}")
os.makedirs(csv_dir, exist_ok=True)


def csv_value(v):
    if v is None:
        return ""
    if isinstance(v, dt.datetime):
        return v.strftime("%Y/%m/%d %H:%M:%S")
    if isinstance(v, bool):
        return "True" if v else "False"
    return str(v)


for tab, headers in HEADERS.items():
    if tab == "vMetaData":
        continue  # RVTools' CSV export has no vMetaData file
    with open(os.path.join(csv_dir, f"RVTools_tab{tab}.csv"), "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh, lineterminator="\r\n")
        w.writerow(headers)
        for r in rows[tab]:
            w.writerow([csv_value(r.get(h)) for h in headers])

print(f"wrote {xlsx_path}")
print(f"wrote {csv_dir}/ ({len(HEADERS) - 1} csv files)")
print(f"{len(vms)} VMs, {len(hosts)} hosts, {len(datastores)} datastores")
