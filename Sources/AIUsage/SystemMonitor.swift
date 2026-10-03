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
        var gpu: Double?        // 0...100, read only while GPU is shown or open
        var temperature: Double? // hottest CPU die sensor, °C, read only while shown or open
        var cpuLevel = SystemLevel.normal
        var memoryLevel = SystemLevel.normal
        var diskLevel = SystemLevel.normal
        var gpuLevel = SystemLevel.normal
        var temperatureLevel = SystemLevel.normal

        func level(_ m: SystemStatusImage.Metric) -> SystemLevel {
            switch m {
            case .cpu: return cpuLevel
            case .gpu: return gpuLevel
            case .memory: return memoryLevel
            case .disk: return diskLevel
            case .sensors: return temperatureLevel
            case .network: return internetLevel
            }
        }
        var internetLevel = SystemLevel.normal
    }

    /// Extra readings for the detail popovers. Filled only while a popover is open.
    struct Details: Equatable {
        var cpu: SystemMath.CPUBreakdown?
        var cores: [Double?] = []
        var load: [Double]?
        var uptime: TimeInterval = 0
        var memory: SystemMath.MemoryBreakdown?
        var swapUsed: UInt64?
        var swapTotal: UInt64?
        var memoryFree: Int?
        var diskTotal: Int64?
        var diskFree: Int64?
        var diskReadTotal: UInt64?
        var diskWriteTotal: UInt64?
        var netSentTotal: UInt64?
        var netReceivedTotal: UInt64?
        var interface: String?
        var localIP: String?
        var coreTypes: [String]?
        var coreLevelNames: [String] = []
        var coreLevelCounts: [Int] = []
        var gpu: GPUReading?
        var sensors: StatusSnapshot.Sensors?
        var battery: BatteryReading?
        var drives: [DriveHealth] = []
        var volumes: [VolumeReading] = []
        var wifi: WiFiReading?
    }

    /// Recent samples (two minutes) for the charts. Kept for every metric so a chart is
    /// already filled when its popover opens.
    struct History: Equatable {
        var cpu: [Double] = [], memory: [Double] = []
        var diskRead: [Double] = [], diskWrite: [Double] = []
        var upload: [Double] = [], download: [Double] = []
        var gpu: [Double] = [], temperature: [Double] = []
    }

    @Published private(set) var reading = Reading()
    @Published private(set) var details = Details()
    @Published private(set) var history = History()
    @Published private(set) var diskRead: Double?
    @Published private(set) var diskWrite: Double?
    @Published private(set) var topProcesses: [ProcessUsage] = []

    /// The metric whose popover is open. Top processes and details are read only while this is set.
    var focus: SystemStatusImage.Metric? {
        didSet {
            guard focus != oldValue else { return }
            topProcesses = []
            lastDiskByProcess = nil
            lastInterfaceCheck = nil
            if focus != nil, isRunning { sampleDetails(); fetchTop() }
        }
    }

    /// Same default as Stats: once a second while something is on screen. With nothing shown (for
    /// example a Mac without a monitor that only keeps its status for other tools) every 5 seconds.
    private(set) var interval: TimeInterval = 1
    /// Metrics shown in the menu bar; GPU and temperatures are read every tick only when shown or open.
    var shown: Set<SystemStatusImage.Metric> = []
    /// Internet check per connection, every minute when enabled (Settings).
    var internetCheckEnabled = false {
        didSet { if internetCheckEnabled != oldValue { lastInternetCheck = nil; if !internetCheckEnabled { refreshConnections() } } }
    }
    @Published private(set) var internet: InternetStatus?
    private var lastInternetCheck: Date?
    private var checkingInternet = false
    /// Two minutes of samples for the charts.
    nonisolated static let historyLength = 120
    private var timer: Timer?
    private var lastCPU: SystemMath.CPUTicks?
    private var lastCores: [SystemMath.CPUTicks]?
    private var cpuBreakdown: SystemMath.CPUBreakdown?
    private var coreUsage: [Double?] = []
    private var lastNet: (counters: SystemMath.NetCounters, at: Date)?
    private var lastDiskIO: (read: UInt64, written: UInt64, at: Date)?
    private var lastDiskCheck: Date?
    private var lastInterfaceCheck: Date?
    private var cachedInterface: (name: String, ip: String?)?
    private var lastDiskByProcess: (bytes: [Int32: (name: String, bytes: UInt64)], at: Date)?
    private var fetchingTop = false
    let hardware = HardwareCache()
    private var lastGPU: GPUReading?

    var isRunning: Bool { timer != nil }

    /// Changes the sampling interval; the chart history restarts so it never mixes intervals.
    func setInterval(_ seconds: TimeInterval) {
        guard seconds != interval, seconds.isFinite, seconds >= 0.5 else { return }
        interval = seconds
        history = History()
        if timer != nil {
            timer?.invalidate()
            timer = nil
            start()
        }
    }

    func start() {
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sample()
                if self?.focus != nil { self?.sampleDetails(); self?.fetchTop() }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastCPU = nil
        lastCores = nil
        cpuBreakdown = nil
        coreUsage = []
        lastNet = nil
        lastDiskIO = nil
        lastDiskByProcess = nil
        reading = Reading()
        details = Details()
        history = History()
        diskRead = nil
        diskWrite = nil
        topProcesses = []
    }

    private func sample() {
        var r = reading
        var h = history
        let now = Date()

        if let ticks = SystemProbe.cpuTicks() {
            if let prev = lastCPU {
                r.cpu = SystemMath.cpuUsage(from: prev, to: ticks)
                cpuBreakdown = SystemMath.cpuBreakdown(from: prev, to: ticks)
            }
            lastCPU = ticks
        }
        // Per-core ticks are cheap; keep them current so the CPU popover has values the moment it opens.
        if let cores = SystemProbe.coreTicks() {
            if let prev = lastCores { coreUsage = SystemMath.coreUsage(from: prev, to: cores) }
            lastCores = cores
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
        var read: Double?, write: Double?
        if let io = SystemProbe.diskIO() {
            if let prev = lastDiskIO {
                let secs = now.timeIntervalSince(prev.at)
                read = SystemMath.rate(from: prev.read, to: io.read, seconds: secs)
                write = SystemMath.rate(from: prev.written, to: io.written, seconds: secs)
            }
            lastDiskIO = (io.read, io.written, now)
        }
        r.memoryLevel = SystemMath.memoryLevel(freePercent: SystemProbe.memoryFreePercent(), pressure: SystemProbe.memoryPressure())
        r.diskLevel = SystemMath.diskLevel(percent: r.disk)
        if r.cpu != nil { h.cpu = SystemMath.appending(limit: Self.historyLength, r.cpu, to: h.cpu) }
        h.memory = SystemMath.appending(limit: Self.historyLength, r.memory, to: h.memory)
        if r.upload != nil || r.download != nil {
            h.upload = SystemMath.appending(limit: Self.historyLength, r.upload, to: h.upload)
            h.download = SystemMath.appending(limit: Self.historyLength, r.download, to: h.download)
        }
        if read != nil || write != nil {
            h.diskRead = SystemMath.appending(limit: Self.historyLength, read, to: h.diskRead)
            h.diskWrite = SystemMath.appending(limit: Self.historyLength, write, to: h.diskWrite)
        }
        r.cpuLevel = r.cpu == nil ? .normal : SystemMath.cpuLevel(recent: h.cpu)
        r.internetLevel = internet.map { SystemLevel(name: $0.level) } ?? .normal
        if lastInternetCheck.map({ now.timeIntervalSince($0) >= 60 || now < $0 }) ?? true { refreshConnections() }
        if shown.contains(.gpu) || focus == .gpu {
            lastGPU = HardwareProbe.gpu()
            r.gpu = lastGPU?.utilizationPercent
            h.gpu = SystemMath.appending(limit: Self.historyLength, r.gpu, to: h.gpu)
            r.gpuLevel = HardwareMath.gpuLevel(r.gpu)
        }
        if shown.contains(.sensors) || focus == .sensors || focus == .cpu {
            let t = HardwareMath.temperatureSummary(HardwareProbe.temperatures())
            r.temperature = t.cpuMax
            if let c = t.cpuMax { h.temperature = SystemMath.appending(limit: Self.historyLength, c, to: h.temperature) }
            r.temperatureLevel = HardwareMath.temperatureLevel(t.cpuMax)
        }
        if r != reading { reading = r }
        if h != history { history = h }
        if read != diskRead { diskRead = read }
        if write != diskWrite { diskWrite = write }
    }

    private func sampleDetails() {
        guard let focus else { return }
        var d = details
        fill(&d, focus, now: Date())
        if d != details { details = d }
    }

    private func fill(_ d: inout Details, _ metric: SystemStatusImage.Metric, now: Date) {
        switch metric {
        case .cpu:
            d.cpu = cpuBreakdown
            d.cores = coreUsage
            d.load = SystemProbe.loadAverage()
            d.uptime = ProcessInfo.processInfo.systemUptime
            let layout = hardware.coreTypes(count: coreUsage.count)
            d.coreTypes = layout.kinds
            d.coreLevelNames = layout.levels.map(\.name)
            d.coreLevelCounts = layout.levels.map(\.count)
        case .gpu:
            d.gpu = lastGPU   // the same reading as the header, taken this tick
        case .sensors:
            d.sensors = StatusSnapshot.Sensors.read()
            d.battery = HardwareProbe.battery()
        case .memory:
            d.memory = SystemProbe.memory().flatMap(SystemMath.memoryBreakdown)
            let swap = SystemProbe.swap()
            d.swapUsed = swap?.used
            d.swapTotal = swap?.total
            d.memoryFree = SystemProbe.memoryFreePercent()
        case .disk:
            if let disk = SystemProbe.disk() { d.diskTotal = disk.total; d.diskFree = disk.available }
            d.diskReadTotal = lastDiskIO?.read
            d.diskWriteTotal = lastDiskIO?.written
            d.drives = hardware.drives(now: now)
            d.volumes = hardware.volumes(now: now)
        case .network:
            d.netSentTotal = lastNet?.counters.sent
            d.netReceivedTotal = lastNet?.counters.received
            // Interface names come from SystemConfiguration, which is slower; refresh every 10 seconds.
            if lastInterfaceCheck.map({ now.timeIntervalSince($0) >= 10 }) ?? true {
                cachedInterface = SystemProbe.primaryInterface()
                lastInterfaceCheck = now
            }
            d.interface = cachedInterface?.name
            d.localIP = cachedInterface?.ip
            d.wifi = hardware.wifi(now: now)
        }
    }

    /// Everything this monitor knows, for the saved status file. Reads the detail values on demand.
    func statusSnapshot() -> StatusSnapshot.SystemStatus {
        var d = Details()
        for m: SystemStatusImage.Metric in [.cpu, .memory, .disk, .network] { fill(&d, m, now: Date()) }
        let r = reading
        let h = history
        let disk = d.diskTotal.flatMap { t in d.diskFree.map { (total: t, available: $0) } }
        let swap = d.swapUsed.flatMap { u in d.swapTotal.map { (used: u, total: $0) } }
        let totals = d.diskReadTotal.flatMap { rd in d.diskWriteTotal.map { (read: rd, written: $0) } }
        let net = lastNet?.counters
        var system = StatusSnapshot.system(
            cpu: .init(usagePercent: r.cpu, level: r.cpuLevel.name, userPercent: d.cpu?.user, systemPercent: d.cpu?.system,
                       idlePercent: d.cpu?.idle, coresPercent: d.cores, loadAverage: d.load),
            memory: d.memory, memoryPercent: r.memory, pressureFree: d.memoryFree, pressure: SystemProbe.memoryPressure(),
            swap: swap, disk: disk, diskPercent: r.disk ?? disk.flatMap { SystemMath.diskUsedPercent(total: $0.total, available: $0.available) },
            diskRead: diskRead, diskWrite: diskWrite, diskTotals: totals,
            download: r.download, upload: r.upload, netTotals: net, interface: d.interface, localIP: d.localIP,
            history: .init(intervalSeconds: interval, cpuPercent: h.cpu, memoryPercent: h.memory,
                           diskReadBytesPerSecond: h.diskRead, diskWriteBytesPerSecond: h.diskWrite,
                           downloadBytesPerSecond: h.download, uploadBytesPerSecond: h.upload,
                           gpuPercent: h.gpu.isEmpty ? nil : h.gpu, cpuTemperatureC: h.temperature.isEmpty ? nil : h.temperature))
        system.addHardware(cache: hardware)
        system.network.internet = internet
        return system
    }

    /// Lists connections and, when enabled, checks the internet through each one, off the main thread.
    private func refreshConnections() {
        guard !checkingInternet else { return }
        checkingInternet = true
        lastInternetCheck = Date()
        let enabled = internetCheckEnabled
        Task.detached(priority: .utility) {
            let status = ConnectivityProbe.status(checkEnabled: enabled)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.checkingInternet = false
                if status != self.internet { self.internet = status }
            }
        }
    }

    /// Reads the busiest processes off the main thread; skipped if the previous read is still running.
    private func fetchTop() {
        guard let metric = focus, [.cpu, .memory, .disk, .network].contains(metric), !fetchingTop else { return }
        fetchingTop = true
        let previous = lastDiskByProcess
        Task.detached(priority: .utility) {
            // The first disk reading needs two snapshots; take them half a second apart so the
            // list appears right away instead of after the next tick.
            var previous = previous
            if metric == .disk, previous == nil {
                previous = (SystemProbe.diskBytesByProcess(), Date())
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            let now = Date()
            let bytes = metric == .disk ? SystemProbe.diskBytesByProcess() : [:]
            let snapshot = (bytes: bytes, at: now)
            let top: [ProcessUsage]
            switch metric {
            case .cpu: top = SystemProbe.topByPS("pcpu", sortFlag: "-r", valueScale: 1)
            case .memory: top = SystemProbe.topByPS("rss", sortFlag: "-m", valueScale: 1024)
            case .disk:
                top = previous.map { SystemMath.topDiskProcesses(from: $0.bytes, to: bytes, seconds: now.timeIntervalSince($0.at)) } ?? []
            case .network: top = HardwareProbe.topNetwork(limit: 5)
            case .gpu, .sensors: top = []
            }
            let hadPrevious = previous != nil
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.fetchingTop = false
                guard self.focus == metric else { return }
                if metric == .disk { self.lastDiskByProcess = snapshot }
                if metric != .disk || hadPrevious { self.topProcesses = top }
            }
        }
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
