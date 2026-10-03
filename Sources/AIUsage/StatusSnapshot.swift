import Darwin
import Foundation
import SystemConfiguration

/// Everything this Mac knows about itself, saved by the running app so other tools can read it
/// (`AIUsage status`, `AIUsage mcp`). Holds no tokens, cookies or account identifiers.
/// Keys are written in snake_case; `schema_version` changes only on incompatible edits.
struct StatusSnapshot: Codable, Equatable {
    static let currentSchema = 1

    var schemaVersion = StatusSnapshot.currentSchema
    var generatedAt: Date
    /// "app": saved by the running app. "live": measured just now by the command (app not running).
    var source: String
    var appVersion: String
    var host: HostInfo
    var system: SystemStatus
    /// Connected providers only. nil when unknown (the app has never saved usage on this Mac).
    var aiUsage: [AIUsageStatus]?

    struct HostInfo: Codable, Equatable {
        var name: String
        var model: String?
        var chip: String?
        var cpuCores: Int?
        var performanceCores: Int?
        var efficiencyCores: Int?
        var memoryBytes: UInt64
        var macosVersion: String
        var uptimeSeconds: Int
    }

    struct SystemStatus: Codable, Equatable {
        var cpu: CPU
        var memory: Memory
        var disk: Disk
        var network: Network
        var history: History?
    }

    struct CPU: Codable, Equatable {
        var usagePercent: Double?
        var level: String
        var userPercent: Double?
        var systemPercent: Double?
        var idlePercent: Double?
        var coresPercent: [Double?]
        var loadAverage: [Double]?
    }

    struct Memory: Codable, Equatable {
        var usedPercent: Double?
        var level: String
        var totalBytes: UInt64
        var usedBytes: UInt64?
        var appBytes: UInt64?
        var wiredBytes: UInt64?
        var compressedBytes: UInt64?
        var cachedBytes: UInt64?
        var freeBytes: UInt64?
        /// Free memory as macOS computes it for memory pressure (what `memory_pressure` prints).
        var pressureFreePercent: Int?
        var swapUsedBytes: UInt64?
        var swapTotalBytes: UInt64?
    }

    struct Disk: Codable, Equatable {
        var usedPercent: Double?
        var level: String
        var totalBytes: Int64?
        var freeBytes: Int64?
        var readBytesPerSecond: Double?
        var writeBytesPerSecond: Double?
        var readSinceBootBytes: UInt64?
        var writtenSinceBootBytes: UInt64?
    }

    struct Network: Codable, Equatable {
        var downloadBytesPerSecond: Double?
        var uploadBytesPerSecond: Double?
        var receivedSinceBootBytes: UInt64?
        var sentSinceBootBytes: UInt64?
        var interface: String?
        var localIp: String?
    }

    struct History: Codable, Equatable {
        var intervalSeconds: Double
        var cpuPercent: [Double]
        var memoryPercent: [Double]
        var diskReadBytesPerSecond: [Double]
        var diskWriteBytesPerSecond: [Double]
        var downloadBytesPerSecond: [Double]
        var uploadBytesPerSecond: [Double]
    }

    struct AIUsageStatus: Codable, Equatable {
        var provider: String
        var connection: String
        var plan: String?
        var fetchedAt: Date?
        var windows: [Window]
        var error: String?

        struct Window: Codable, Equatable {
            var kind: String
            var label: String
            var usedPercent: Double?
            var remainingPercent: Double?
            var resetsAt: Date?
            var windowMinutes: Int?
        }
    }

    /// Percentages to 0.1 and rates to whole bytes: enough for people and AIs, far less noise.
    func rounded() -> StatusSnapshot {
        func p(_ v: Double?) -> Double? { v.map { $0.isFinite ? ($0 * 10).rounded() / 10 : $0 } }
        func r(_ v: Double?) -> Double? { v.map { $0.isFinite ? $0.rounded() : $0 } }
        var s = self
        s.system.cpu.usagePercent = p(s.system.cpu.usagePercent)
        s.system.cpu.userPercent = p(s.system.cpu.userPercent)
        s.system.cpu.systemPercent = p(s.system.cpu.systemPercent)
        s.system.cpu.idlePercent = p(s.system.cpu.idlePercent)
        s.system.cpu.coresPercent = s.system.cpu.coresPercent.map(p)
        s.system.cpu.loadAverage = s.system.cpu.loadAverage?.map { ($0 * 100).rounded() / 100 }
        s.system.memory.usedPercent = p(s.system.memory.usedPercent)
        s.system.disk.usedPercent = p(s.system.disk.usedPercent)
        s.system.disk.readBytesPerSecond = r(s.system.disk.readBytesPerSecond)
        s.system.disk.writeBytesPerSecond = r(s.system.disk.writeBytesPerSecond)
        s.system.network.downloadBytesPerSecond = r(s.system.network.downloadBytesPerSecond)
        s.system.network.uploadBytesPerSecond = r(s.system.network.uploadBytesPerSecond)
        if var h = s.system.history {
            h.cpuPercent = h.cpuPercent.compactMap(p)
            h.memoryPercent = h.memoryPercent.compactMap(p)
            h.diskReadBytesPerSecond = h.diskReadBytesPerSecond.compactMap(r)
            h.diskWriteBytesPerSecond = h.diskWriteBytesPerSecond.compactMap(r)
            h.downloadBytesPerSecond = h.downloadBytesPerSecond.compactMap(r)
            h.uploadBytesPerSecond = h.uploadBytesPerSecond.compactMap(r)
            s.system.history = h
        }
        s.aiUsage = s.aiUsage?.map { u in
            var u = u
            u.windows = u.windows.map { var w = $0; w.usedPercent = p(w.usedPercent); w.remainingPercent = p(w.remainingPercent); return w }
            return u
        }
        return s
    }

    // MARK: Coding

    static func encoder(pretty: Bool = false) -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return d
    }

    /// Parses a saved file; nil for anything unreadable or from an incompatible schema.
    static func decode(_ data: Data) -> StatusSnapshot? {
        guard let s = try? decoder().decode(StatusSnapshot.self, from: data), s.schemaVersion == currentSchema else { return nil }
        return s
    }
}

extension SystemLevel {
    var name: String {
        switch self {
        case .normal: return "normal"
        case .warning: return "warning"
        case .critical: return "critical"
        }
    }
}

// MARK: - Where it lives

enum StatusFile {
    /// ~/Library/Application Support/AI Usage/status.json (readable by this user only).
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AI Usage", isDirectory: true)
            .appendingPathComponent("status.json")
    }

    /// The app saves every few seconds; an older file means the app isn't running (or is stuck).
    static let freshFor: TimeInterval = 30

    static func read(at url: URL = url) -> StatusSnapshot? {
        guard let data = try? Data(contentsOf: url), data.count < 4_000_000 else { return nil }
        return StatusSnapshot.decode(data)
    }

    /// Atomic write, folder 0700 and file 0600 so other accounts on the Mac can't read it.
    static func write(_ snapshot: StatusSnapshot, to url: URL = url) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try StatusSnapshot.encoder().encode(snapshot.rounded())
        let tmp = dir.appendingPathComponent(".status-\(getpid()).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if rename(tmp.path, url.path) != 0 {
            try? FileManager.default.removeItem(at: tmp)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Whether a saved snapshot is recent enough to stand for "now".
    static func isFresh(_ s: StatusSnapshot, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(s.generatedAt)
        return age >= -60 && age <= freshFor
    }
}

// MARK: - Building

extension SystemProbe {
    static func host() -> StatusSnapshot.HostInfo {
        func sysctlString(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0, size < 1024 else { return nil }
            var buf = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
            return String(cString: buf)
        }
        func sysctlInt(_ name: String) -> Int? {
            var v: Int32 = 0
            var size = MemoryLayout<Int32>.size
            return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : nil
        }
        let info = ProcessInfo.processInfo
        let v = info.operatingSystemVersion
        let name = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? info.hostName
        // perflevel0 = performance cores, perflevel1 = efficiency cores (Apple Silicon only).
        let p = sysctlInt("hw.perflevel0.logicalcpu"), e = sysctlInt("hw.perflevel1.logicalcpu")
        return .init(name: name, model: sysctlString("hw.model"), chip: sysctlString("machdep.cpu.brand_string"),
                     cpuCores: info.activeProcessorCount, performanceCores: e == nil ? nil : p, efficiencyCores: e,
                     memoryBytes: info.physicalMemory,
                     macosVersion: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
                     uptimeSeconds: Int(info.systemUptime))
    }
}

extension StatusSnapshot {
    /// Rates and breakdowns need two samples; `LiveSample` holds both ends.
    struct LiveSample {
        var cpu: (SystemMath.CPUTicks, SystemMath.CPUTicks)?
        var cores: ([SystemMath.CPUTicks], [SystemMath.CPUTicks])?
        var net: (SystemMath.NetCounters, SystemMath.NetCounters)?
        var diskIO: ((read: UInt64, written: UInt64), (read: UInt64, written: UInt64))?
        var seconds: TimeInterval
    }

    /// Measures for `seconds` (the command uses this when the app isn't running). Blocks the caller.
    static func measure(seconds: TimeInterval = 1) -> LiveSample {
        let c0 = SystemProbe.cpuTicks(), k0 = SystemProbe.coreTicks(), n0 = SystemProbe.networkCounters(), d0 = SystemProbe.diskIO()
        let start = Date()
        Thread.sleep(forTimeInterval: seconds)
        let c1 = SystemProbe.cpuTicks(), k1 = SystemProbe.coreTicks(), n1 = SystemProbe.networkCounters(), d1 = SystemProbe.diskIO()
        let secs = Date().timeIntervalSince(start)
        return LiveSample(cpu: c0.flatMap { a in c1.map { (a, $0) } }, cores: k0.flatMap { a in k1.map { (a, $0) } },
                          net: n0.flatMap { a in n1.map { (a, $0) } }, diskIO: d0.flatMap { a in d1.map { (a, $0) } },
                          seconds: secs)
    }

    /// System section from a fresh measurement.
    static func system(from s: LiveSample) -> SystemStatus {
        let cpuUsage = s.cpu.flatMap { SystemMath.cpuUsage(from: $0.0, to: $0.1) }
        let breakdown = s.cpu.flatMap { SystemMath.cpuBreakdown(from: $0.0, to: $0.1) }
        let net = s.net.flatMap { SystemMath.networkRate(from: $0.0, to: $0.1, seconds: s.seconds) }
        let mem = SystemProbe.memory()
        let disk = SystemProbe.disk()
        let diskPercent = disk.flatMap { SystemMath.diskUsedPercent(total: $0.total, available: $0.available) }
        let iface = SystemProbe.primaryInterface()
        let swap = SystemProbe.swap()
        let free = SystemProbe.memoryFreePercent()
        return system(
            cpu: .init(usagePercent: cpuUsage,
                       level: SystemMath.cpuLevel(recent: cpuUsage.map { [$0] } ?? []).name,
                       userPercent: breakdown?.user, systemPercent: breakdown?.system, idlePercent: breakdown?.idle,
                       coresPercent: s.cores.map { SystemMath.coreUsage(from: $0.0, to: $0.1) } ?? [],
                       loadAverage: SystemProbe.loadAverage()),
            memory: mem.flatMap(SystemMath.memoryBreakdown), memoryPercent: mem.flatMap(SystemMath.memoryUsedPercent),
            pressureFree: free, pressure: SystemProbe.memoryPressure(), swap: swap,
            disk: disk, diskPercent: diskPercent,
            diskRead: s.diskIO.flatMap { SystemMath.rate(from: $0.0.read, to: $0.1.read, seconds: s.seconds) },
            diskWrite: s.diskIO.flatMap { SystemMath.rate(from: $0.0.written, to: $0.1.written, seconds: s.seconds) },
            diskTotals: s.diskIO?.1,
            download: net?.down, upload: net?.up, netTotals: s.net?.1, interface: iface?.name, localIP: iface?.ip,
            history: nil)
    }

    /// Shared assembly for the app and the command.
    static func system(cpu: CPU, memory m: SystemMath.MemoryBreakdown?, memoryPercent: Double?,
                       pressureFree: Int?, pressure: Int?, swap: (used: UInt64, total: UInt64)?,
                       disk: (total: Int64, available: Int64)?, diskPercent: Double?,
                       diskRead: Double?, diskWrite: Double?, diskTotals: (read: UInt64, written: UInt64)?,
                       download: Double?, upload: Double?, netTotals: SystemMath.NetCounters?,
                       interface: String?, localIP: String?, history: History?) -> SystemStatus {
        SystemStatus(
            cpu: cpu,
            memory: .init(usedPercent: memoryPercent,
                          level: SystemMath.memoryLevel(freePercent: pressureFree, pressure: pressure).name,
                          totalBytes: m?.total ?? ProcessInfo.processInfo.physicalMemory,
                          usedBytes: m?.used, appBytes: m?.app, wiredBytes: m?.wired, compressedBytes: m?.compressed,
                          cachedBytes: m?.cache, freeBytes: m?.free, pressureFreePercent: pressureFree,
                          swapUsedBytes: swap?.used, swapTotalBytes: swap?.total),
            disk: .init(usedPercent: diskPercent, level: SystemMath.diskLevel(percent: diskPercent).name,
                        totalBytes: disk?.total, freeBytes: disk?.available,
                        readBytesPerSecond: diskRead, writeBytesPerSecond: diskWrite,
                        readSinceBootBytes: diskTotals?.read, writtenSinceBootBytes: diskTotals?.written),
            network: .init(downloadBytesPerSecond: download, uploadBytesPerSecond: upload,
                           receivedSinceBootBytes: netTotals?.received, sentSinceBootBytes: netTotals?.sent,
                           interface: interface, localIp: localIP),
            history: history)
    }

    /// Usage for one connected provider, as shown in the app (reset windows already count as fresh).
    static func aiUsage(provider: Provider, connection: Connection, snapshot: ProviderSnapshot?,
                        error: ProviderError?, now: Date) -> AIUsageStatus {
        let windows = (snapshot?.windows ?? []).map { $0.effective(at: now) }.map { w -> AIUsageStatus.Window in
            let kind: String
            switch w.kind {
            case .session: kind = "session_5h"
            case .weekly: kind = "weekly"
            case .weeklyModel: kind = "weekly_model"
            case .other: kind = "other"
            }
            return .init(kind: kind, label: w.kind.title,
                         usedPercent: w.usedPercent.isFinite ? w.usedPercent : nil,
                         remainingPercent: w.usedPercent.isFinite ? w.remainingPercent : nil,
                         resetsAt: w.resetsAt, windowMinutes: w.windowMinutes)
        }
        return .init(provider: provider.rawValue, connection: connection.rawValue, plan: snapshot?.plan,
                     fetchedAt: snapshot?.fetchedAt, windows: windows, error: error?.message)
    }
}
