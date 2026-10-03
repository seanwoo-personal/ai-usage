import AppKit
import Darwin
import IOKit
import SystemConfiguration

// Detail readings behind the CPU / RAM / SSD / network popovers. Public macOS interfaces only:
// Mach host statistics, sysctl, IOKit block-storage statistics, getifaddrs, proc_pid_rusage and `ps`.
// Nothing here needs admin rights, a helper tool or a network request.

struct ProcessUsage: Identifiable, Equatable {
    let pid: Int32
    let name: String
    let value: Double        // CPU %, memory bytes, or disk bytes per second
    var id: Int32 { pid }
}

extension SystemMath {
    struct CPUBreakdown: Equatable { var user, system, idle: Double }

    /// User / system / idle shares between two samples (nice time counts as user, as in Activity Monitor).
    static func cpuBreakdown(from a: CPUTicks, to b: CPUTicks) -> CPUBreakdown? {
        guard b.user >= a.user, b.system >= a.system, b.idle >= a.idle, b.nice >= a.nice else { return nil }
        let user = Double(b.user - a.user + b.nice - a.nice)
        let system = Double(b.system - a.system)
        let idle = Double(b.idle - a.idle)
        let total = user + system + idle
        guard total > 0 else { return nil }
        return .init(user: user / total * 100, system: system / total * 100, idle: idle / total * 100)
    }

    /// Per-core usage; cores whose counters didn't advance or went backwards are skipped as nil.
    static func coreUsage(from a: [CPUTicks], to b: [CPUTicks]) -> [Double?] {
        guard a.count == b.count else { return b.map { _ in nil } }
        return zip(a, b).map { cpuUsage(from: $0, to: $1) }
    }

    struct MemoryBreakdown: Equatable {
        var total, used, app, wired, compressed, cache, free: UInt64
    }

    /// Stats' split: used = app + wired + compressed; cache = purgeable + file-backed pages; free = total − used.
    static func memoryBreakdown(_ m: Memory) -> MemoryBreakdown? {
        guard let percent = memoryUsedPercent(m) else { return nil }
        let used = UInt64(Double(m.physical) * percent / 100)
        let wired = m.wired &* m.pageSize, compressed = m.compressed &* m.pageSize
        let app = used > wired &+ compressed ? used - wired - compressed : 0
        let cache = (m.purgeable &+ m.external) &* m.pageSize
        return .init(total: m.physical, used: used, app: app, wired: wired, compressed: compressed,
                     cache: cache, free: m.physical > used ? m.physical - used : 0)
    }

    /// Bytes per second between two cumulative counters (disk or network); nil if a counter went backwards.
    static func rate(from a: UInt64, to b: UInt64, seconds: TimeInterval) -> Double? {
        guard seconds.isFinite, seconds >= 0.2, b >= a else { return nil }
        return Double(b - a) / seconds
    }

    /// "512 MB", "18.7 GB", "1.2 TB".
    static func bytesText(_ bytes: Double?) -> String {
        guard let b = bytes, b.isFinite, b >= 0 else { return "–" }
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var v = b, i = 0
        while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
        return i == 0 ? "\(Int(v)) B" : String(format: v < 10 ? "%.1f %@" : "%.0f %@", v, units[i])
    }

    /// "3일 4시간" / "3d 4h" style uptime.
    static func uptimeText(_ seconds: TimeInterval) -> String {
        let mins = L.minutes(seconds)
        let d = mins / 1440, h = (mins % 1440) / 60, m = mins % 60
        if d > 0 { return L.t("\(d)일 \(h)시간", "\(d)d \(h)h") }
        if h > 0 { return L.t("\(h)시간 \(m)분", "\(h)h \(m)m") }
        return L.t("\(m)분", "\(m)m")
    }

    /// Parses `ps -Aceo pid=,<value>=,comm=` output: "  123  4.5 Safari". Malformed lines are skipped.
    static func parsePS(_ text: String, valueScale: Double = 1) -> [ProcessUsage] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]), pid > 0,
                  let v = Double(parts[1].replacingOccurrences(of: ",", with: ".")), v.isFinite, v >= 0 else { return nil }
            let name = String(parts[2]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return ProcessUsage(pid: pid, name: name, value: v * valueScale)
        }
    }

    /// Memory pressure level from `kern.memorystatus_vm_pressure_level` (1 normal, 2 warning, 4 critical).
    static func pressureText(_ level: SystemLevel, freePercent: Int?) -> String {
        guard let free = freePercent, (0...100).contains(free) else { return "–" }
        let word: String
        switch level {
        case .normal: word = L.t("정상", "Normal")
        case .warning: word = L.t("주의", "Warning")
        case .critical: word = L.t("위험", "Critical")
        }
        return word + L.t(" (여유 \(free)%)", " (\(free)% free)")
    }

    /// Keeps the newest `limit` values.
    static func appending(limit: Int = 60, _ value: Double?, to history: [Double]) -> [Double] {
        var h = history
        h.append(value.flatMap { $0.isFinite ? $0 : nil } ?? 0)
        if h.count > limit { h.removeFirst(h.count - limit) }
        return h
    }
}

extension SystemProbe {
    static func coreTicks() -> [SystemMath.CPUTicks]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
        let stride = Int(CPU_STATE_MAX)
        return (0..<Int(cpuCount)).map { c in
            let base = c * stride
            return SystemMath.CPUTicks(user: UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)])),
                                       system: UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)])),
                                       idle: UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)])),
                                       nice: UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])))
        }
    }

    static func loadAverage() -> [Double]? {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) == 3 ? loads : nil
    }

    static func swap() -> (used: UInt64, total: UInt64)? {
        var s = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &s, &size, nil, 0) == 0 else { return nil }
        return (s.xsu_used, s.xsu_total)
    }

    /// Free memory share, 0...100, as the kernel computes it for memory pressure.
    static func memoryFreePercent() -> Int? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0 ? Int(level) : nil
    }

    static func memoryPressure() -> Int? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 ? Int(level) : nil
    }

    /// Cumulative bytes read and written by all block-storage drivers since boot.
    static func diskIO() -> (read: UInt64, written: UInt64)? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        var read: UInt64 = 0, written: UInt64 = 0
        var service = IOIteratorNext(iter)
        while service != 0 {
            if let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                read &+= (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                written &+= (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iter)
        }
        return (read, written)
    }

    /// The busiest hardware interface's display name ("Wi-Fi", "Ethernet") and its IPv4 address.
    static func primaryInterface() -> (name: String, ip: String?)? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
        defer { freeifaddrs(addrs) }
        var best: (bsd: String, bytes: UInt64)?
        var ips: [String: String] = [:]
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = p {
            let name = String(cString: ifa.pointee.ifa_name)
            let flags = Int32(ifa.pointee.ifa_flags)
            if name.hasPrefix("en"), flags & IFF_UP != 0, flags & IFF_RUNNING != 0, let sa = ifa.pointee.ifa_addr {
                if sa.pointee.sa_family == UInt8(AF_LINK), let data = ifa.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                    let bytes = UInt64(data.pointee.ifi_ibytes) + UInt64(data.pointee.ifi_obytes)
                    if bytes > (best?.bytes ?? 0) { best = (name, bytes) }
                } else if sa.pointee.sa_family == UInt8(AF_INET) {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        ips[name] = String(cString: host)
                    }
                }
            }
            p = ifa.pointee.ifa_next
        }
        guard let bsd = best?.bsd ?? ips.keys.sorted().first else { return nil }
        var display = bsd
        if let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for i in all where (SCNetworkInterfaceGetBSDName(i) as String?) == bsd {
                display = (SCNetworkInterfaceGetLocalizedDisplayName(i) as String?) ?? bsd
            }
        }
        return (display, ips[bsd])
    }

    /// Top processes from `ps` (runs only while a detail popover is open).
    static func topByPS(_ column: String, sortFlag: String, valueScale: Double, limit: Int = 5) -> [ProcessUsage] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-Aceo", "pid=,\(column)=,comm=", sortFlag]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Array(SystemMath.parsePS(String(decoding: data, as: UTF8.self), valueScale: valueScale).prefix(limit))
    }

    /// Cumulative disk bytes per process (only processes this user may inspect).
    static func diskBytesByProcess() -> [Int32: (name: String, bytes: UInt64)] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [:] }
        var pids = [Int32](repeating: 0, count: Int(count) + 32)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard n > 0 else { return [:] }
        var result: [Int32: (String, UInt64)] = [:]
        for pid in pids.prefix(Int(n)) where pid > 0 {
            var info = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            guard ok == 0 else { continue }
            var nameBuf = [CChar](repeating: 0, count: 256)
            proc_name(pid, &nameBuf, UInt32(nameBuf.count))
            let name = String(cString: nameBuf)
            guard !name.isEmpty else { continue }
            result[pid] = (name, info.ri_diskio_bytesread &+ info.ri_diskio_byteswritten)
        }
        return result
    }
}

/// How worrying a reading is; drives the yellow / red colour in the menu bar and popovers.
enum SystemLevel: Int, Comparable {
    case normal, warning, critical
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

extension SystemMath {
    /// CPU: the average of the last five seconds, so a brief spike doesn't flash the colour.
    /// 70% or more is yellow, 90% or more red.
    static func cpuLevel(recent: [Double], seconds: Int = 5) -> SystemLevel {
        let window = recent.suffix(seconds).filter(\.isFinite)
        guard !window.isEmpty else { return .normal }
        let avg = window.reduce(0, +) / Double(window.count)
        return avg >= 90 ? .critical : avg >= 70 ? .warning : .normal
    }

    /// RAM: macOS keeps memory full of cache on purpose, so a high percentage is normal. Use the
    /// kernel's free-memory share (`kern.memorystatus_level`, as `memory_pressure` prints it) instead:
    /// under 20% yellow, under 10% red. The kernel's own "critical" state is red too; its "warning"
    /// state alone is ignored because it lingers long after memory frees up.
    static func memoryLevel(freePercent: Int?, pressure: Int?) -> SystemLevel {
        if pressure == 4 { return .critical }
        guard let free = freePercent, (0...100).contains(free) else { return .normal }
        return free < 10 ? .critical : free < 20 ? .warning : .normal
    }

    /// SSD: 90% used or more is yellow, 95% or more red (macOS starts struggling near full).
    static func diskLevel(percent: Double?) -> SystemLevel {
        guard let p = percent, p.isFinite else { return .normal }
        return p >= 95 ? .critical : p >= 90 ? .warning : .normal
    }
}

extension SystemMath {
    /// Busiest disk users between two per-process snapshots, in bytes per second. Processes that
    /// started, ended or whose counters went backwards in between are left out.
    static func topDiskProcesses(from a: [Int32: (name: String, bytes: UInt64)], to b: [Int32: (name: String, bytes: UInt64)],
                                 seconds: TimeInterval, limit: Int = 5) -> [ProcessUsage] {
        b.compactMap { pid, now -> ProcessUsage? in
            guard let before = a[pid], before.name == now.name,
                  let r = rate(from: before.bytes, to: now.bytes, seconds: seconds), r > 0 else { return nil }
            return ProcessUsage(pid: pid, name: now.name, value: r)
        }
        .sorted { $0.value != $1.value ? $0.value > $1.value : $0.pid < $1.pid }
        .prefix(limit).map { $0 }
    }
}
