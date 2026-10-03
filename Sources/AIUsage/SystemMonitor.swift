import AppKit
import Darwin

/// CPU, memory, startup-disk and network readings for the optional system section of the menu bar.
/// Uses only public macOS interfaces (Mach host statistics, sysctl, file-system capacity), so it needs
/// no helper tool, admin rights or extra permissions. Calculations are pure functions, tested separately.
/// The approach follows the open-source Stats app (github.com/exelban/stats, MIT).
@MainActor
final class SystemMonitor: ObservableObject {
    struct Reading: Equatable {
        var cpu: Double?        // 0...100
        var memory: Double?     // 0...100
        var disk: Double?       // 0...100
        var upload: Double?     // bytes per second
        var download: Double?   // bytes per second
    }

    @Published private(set) var reading = Reading()

    static let interval: TimeInterval = 2
    private var timer: Timer?
    private var lastCPU: SystemMath.CPUTicks?
    private var lastNet: (counters: SystemMath.NetCounters, at: Date)?
    private var lastDiskCheck: Date?

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastCPU = nil
        lastNet = nil
        reading = Reading()
    }

    private func sample() {
        var r = reading
        let now = Date()

        if let ticks = SystemProbe.cpuTicks() {
            if let prev = lastCPU { r.cpu = SystemMath.cpuUsage(from: prev, to: ticks) }
            lastCPU = ticks
        }
        if let mem = SystemProbe.memory() { r.memory = SystemMath.memoryUsedPercent(mem) }
        // Disk usage changes slowly; check every 30 seconds.
        if lastDiskCheck.map({ now.timeIntervalSince($0) >= 30 }) ?? true {
            if let d = SystemProbe.disk() { r.disk = SystemMath.diskUsedPercent(total: d.total, available: d.available) }
            lastDiskCheck = now
        }
        if let counters = SystemProbe.networkCounters() {
            if let prev = lastNet {
                let rate = SystemMath.networkRate(from: prev.counters, to: counters, seconds: now.timeIntervalSince(prev.at))
                r.upload = rate?.up
                r.download = rate?.down
            }
            lastNet = (counters, now)
        }
        if r != reading { reading = r }
    }
}

// MARK: - Pure calculations (tested)

enum SystemMath {
    struct CPUTicks: Equatable { var user, system, idle, nice: UInt64 }

    struct Memory: Equatable {
        var pageSize: UInt64
        var active: UInt64, inactive: UInt64, speculative: UInt64, wired: UInt64, compressed: UInt64
        var purgeable: UInt64, external: UInt64
        var physical: UInt64
    }

    struct NetCounters: Equatable { var sent: UInt64, received: UInt64 }

    /// Busy share of CPU time between two samples, 0...100. nil if no time passed or counters went backwards.
    static func cpuUsage(from a: CPUTicks, to b: CPUTicks) -> Double? {
        guard b.user >= a.user, b.system >= a.system, b.idle >= a.idle, b.nice >= a.nice else { return nil }
        let busy = Double((b.user - a.user) + (b.system - a.system) + (b.nice - a.nice))
        let total = busy + Double(b.idle - a.idle)
        guard total > 0 else { return nil }
        return clampPercent(busy / total * 100)
    }

    /// Memory in use, counted the way Stats does: active + inactive + speculative + wired + compressed,
    /// minus purgeable and file-backed (external) pages that macOS can drop at any time.
    static func memoryUsedPercent(_ m: Memory) -> Double? {
        guard m.physical > 0, m.pageSize > 0 else { return nil }
        var pages: UInt64 = 0
        for part in [m.active, m.inactive, m.speculative, m.wired, m.compressed] {
            let (sum, overflow) = pages.addingReportingOverflow(part)
            guard !overflow else { return nil }
            pages = sum
        }
        let reclaimable = m.purgeable &+ m.external
        pages = pages > reclaimable ? pages - reclaimable : 0
        let (bytes, overflow) = pages.multipliedReportingOverflow(by: m.pageSize)
        guard !overflow else { return nil }
        return clampPercent(Double(bytes) / Double(m.physical) * 100)
    }

    /// Used share of the startup disk, counting space macOS can free on demand as available (like Finder).
    static func diskUsedPercent(total: Int64, available: Int64) -> Double? {
        guard total > 0, available >= 0, available <= total else { return nil }
        return clampPercent(Double(total - available) / Double(total) * 100)
    }

    /// Bytes per second between two samples. A counter that went backwards (interface reset,
    /// sleep, VPN coming and going) gives no reading rather than a huge or negative number.
    static func networkRate(from a: NetCounters, to b: NetCounters, seconds: TimeInterval) -> (up: Double, down: Double)? {
        guard seconds.isFinite, seconds >= 0.2, b.sent >= a.sent, b.received >= a.received else { return nil }
        return (Double(b.sent - a.sent) / seconds, Double(b.received - a.received) / seconds)
    }

    private static func clampPercent(_ v: Double) -> Double? { v.isFinite ? max(0, min(100, v)) : nil }

    /// "0 KB/s", "12 KB/s", "1.4 MB/s", "120 MB/s" — fixed short width for the menu bar.
    static func rateText(_ bytesPerSecond: Double?) -> String {
        guard let b = bytesPerSecond, b.isFinite, b >= 0 else { return "– KB/s" }
        let kb = b / 1024
        if kb < 1000 { return "\(Int(kb.rounded())) KB/s" }
        let mb = kb / 1024
        if mb < 10 { return String(format: "%.1f MB/s", mb) }
        if mb < 1000 { return "\(Int(mb.rounded())) MB/s" }
        return String(format: "%.1f GB/s", mb / 1024)
    }

    static func percentText(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "–" }
        return "\(Int(max(0, min(100, v)).rounded()))%"
    }
}

// MARK: - System readings

enum SystemProbe {
    static func cpuTicks() -> SystemMath.CPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        return .init(user: UInt64(t.0), system: UInt64(t.1), idle: UInt64(t.2), nice: UInt64(t.3))
    }

    static func memory() -> SystemMath.Memory? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }
        var m = SystemMath.Memory(pageSize: UInt64(pageSize), active: 0, inactive: 0, speculative: 0, wired: 0,
                                  compressed: 0, purgeable: 0, external: 0, physical: ProcessInfo.processInfo.physicalMemory)
        m.active = UInt64(stats.active_count)
        m.inactive = UInt64(stats.inactive_count)
        m.speculative = UInt64(stats.speculative_count)
        m.wired = UInt64(stats.wire_count)
        m.compressed = UInt64(stats.compressor_page_count)
        m.purgeable = UInt64(stats.purgeable_count)
        m.external = UInt64(stats.external_page_count)
        return m
    }

    static func disk() -> (total: Int64, available: Int64)? {
        let url = URL(fileURLWithPath: "/")
        guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = v.volumeTotalCapacity, let available = v.volumeAvailableCapacityForImportantUsage else { return nil }
        return (Int64(total), available)
    }

    /// 64-bit byte counters summed over active hardware interfaces (Wi-Fi, Ethernet), skipping
    /// loopback and virtual tunnels so VPN traffic isn't counted twice.
    static func networkCounters() -> SystemMath.NetCounters? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return nil }
        var sent: UInt64 = 0, received: UInt64 = 0
        var offset = 0
        while offset + MemoryLayout<if_msghdr>.size <= len {
            let msgLen = buf.withUnsafeBytes { Int($0.load(fromByteOffset: offset, as: if_msghdr.self).ifm_msglen) }
            guard msgLen > 0 else { break }
            let type = buf.withUnsafeBytes { Int32($0.load(fromByteOffset: offset, as: if_msghdr.self).ifm_type) }
            if type == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= len {
                let m = buf.withUnsafeBytes { $0.load(fromByteOffset: offset, as: if_msghdr2.self) }
                var nameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                if if_indextoname(UInt32(m.ifm_index), &nameBuf) != nil {
                    let name = String(cString: nameBuf)
                    let isUp = (m.ifm_flags & IFF_UP) != 0 && (m.ifm_flags & IFF_LOOPBACK) == 0
                    if isUp && (name.hasPrefix("en") || name.hasPrefix("bridge")) {
                        sent &+= m.ifm_data.ifi_obytes
                        received &+= m.ifm_data.ifi_ibytes
                    }
                }
            }
            offset += msgLen
        }
        return .init(sent: sent, received: received)
    }
}
