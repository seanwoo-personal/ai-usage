import CoreWLAN
import Foundation
import IOKit
import IOKit.ps

// Hardware readings beyond CPU/memory/disk/network: core types, GPU, temperatures, fans, power,
// drive health, volumes, Wi-Fi and battery. Everything is read-only and needs no admin rights.
// Temperatures (IOHIDEventSystem) and fans/power (AppleSMC) use private but long-stable macOS
// interfaces, the same ones Stats uses; if a macOS update changes them the values are simply missing.
// Pure parsing lives in `HardwareMath` and is tested; the probes here only gather raw values.

struct GPUReading: Codable, Equatable {
    var level = "normal"
    var model: String?
    var cores: Int?
    var utilizationPercent: Double?
    var rendererPercent: Double?
    var tilerPercent: Double?
    var memoryInUseBytes: UInt64?
}

struct TemperatureReading: Codable, Equatable {
    var name: String
    var celsius: Double
}

struct FanReading: Codable, Equatable {
    var index: Int
    var rpm: Double
    var minRpm: Double?
    var maxRpm: Double?
}

struct DriveHealth: Codable, Equatable {
    var model: String?
    var level: String
    var temperatureC: Int?
    var percentageUsed: Int?
    var availableSparePercent: Int?
    var availableSpareThresholdPercent: Int?
    var criticalWarning: Int
    var powerCycles: UInt64
    var powerOnHours: UInt64
    var unsafeShutdowns: UInt64
    var mediaErrors: UInt64
    var dataReadBytes: UInt64
    var dataWrittenBytes: UInt64
}

struct VolumeReading: Codable, Equatable {
    var name: String
    var totalBytes: Int64
    var freeBytes: Int64
    var usedPercent: Double?
    var fileSystem: String?
    var isInternal: Bool?
    var isRemovable: Bool?
    var isStartup: Bool
}

struct WiFiReading: Codable, Equatable {
    var interface: String
    /// Needs Location Services permission on macOS 14+; nil otherwise (no prompt is shown).
    var ssid: String?
    var rssiDbm: Int?
    var noiseDbm: Int?
    var channel: Int?
    var bandGhz: Double?
    var transmitRateMbps: Double?
}

struct BatteryReading: Codable, Equatable {
    var percent: Int?
    var charging: Bool
    var pluggedIn: Bool
    var minutesRemaining: Int?
    var cycleCount: Int?
    var healthPercent: Double?
    var temperatureC: Double?
}

struct CoreGroup: Codable, Equatable {
    /// macOS's name for the group, lowercased: "efficiency", "performance", "super", ...
    var kind: String
    var count: Int
    var usagePercent: Double?
}

enum HardwareMath {
    /// Cluster letters in logical-CPU order from IODeviceTree entries ("E", "P", "M", ...; Apple Silicon only).
    static func coreTypes(_ entries: [(logicalID: Int, cluster: String)], count: Int) -> [String]? {
        guard count > 0, entries.count == count else { return nil }
        var types = [String?](repeating: nil, count: count)
        for e in entries where (0..<count).contains(e.logicalID) { types[e.logicalID] = e.cluster }
        let all = types.compactMap { $0 }
        return all.count == count ? all : nil
    }

    /// Names each core by macOS's performance levels (`hw.perflevelN.name`, fastest first). The letters
    /// differ between chips (M5 Pro: "P" = Super, "M" = Performance), so groups are matched by core count;
    /// if counts are ambiguous, "P" is the fastest level and "E" the slowest.
    static func coreKinds(letters: [String], levels: [(name: String, count: Int)]) -> [String]? {
        guard !letters.isEmpty, !levels.isEmpty else { return nil }
        var order: [String] = []
        for l in letters where !order.contains(l) { order.append(l) }
        let counts = Dictionary(order.map { l in (l, letters.filter { $0 == l }.count) }, uniquingKeysWith: { a, _ in a })
        var map: [String: String] = [:]
        let levelCounts = levels.map(\.count)
        if order.count == levels.count, order.allSatisfy({ l in levelCounts.filter { $0 == counts[l] }.count == 1 }) {
            for l in order { map[l] = levels.first { $0.count == counts[l] }!.name.lowercased() }
        } else if Set(order).isSubset(of: ["E", "P"]), levels.count == order.count {
            map["P"] = levels.first?.name.lowercased()
            map["E"] = levels.last?.name.lowercased()
        } else {
            return nil
        }
        let kinds = letters.compactMap { map[$0] }
        return kinds.count == letters.count ? kinds : nil
    }

    /// Per-group averages in performance-level order (fastest first).
    static func coreGroups(_ cores: [Double?], kinds: [String]?, levels: [(name: String, count: Int)]) -> [CoreGroup]? {
        guard let kinds, kinds.count == cores.count else { return nil }
        return levels.map { $0.name.lowercased() }.filter(kinds.contains).map { k in
            CoreGroup(kind: k, count: kinds.filter { $0 == k }.count, usagePercent: average(cores, types: kinds, kind: k))
        }
    }

    /// Average of the cores of one kind; nil if none of that kind has a reading.
    static func average(_ cores: [Double?], types: [String]?, kind: String) -> Double? {
        guard let types, types.count == cores.count else { return nil }
        let values = zip(cores, types).compactMap { $1 == kind ? $0 : nil }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    static func percent(_ v: Any?) -> Double? {
        guard let n = (v as? NSNumber)?.doubleValue, n.isFinite, (0...100).contains(n) else { return nil }
        return n
    }

    /// GPU figures from an IOAccelerator `PerformanceStatistics` dictionary.
    static func gpu(stats: [String: Any], model: String?, cores: Int?) -> GPUReading {
        GPUReading(model: model, cores: cores,
                   utilizationPercent: percent(stats["Device Utilization %"]),
                   rendererPercent: percent(stats["Renderer Utilization %"]),
                   tilerPercent: percent(stats["Tiler Utilization %"]),
                   memoryInUseBytes: (stats["In use system memory"] as? NSNumber)?.uint64Value)
    }

    /// Plausible temperatures only (sensors report junk such as -127 or 0 when idle or absent).
    static func validTemperature(_ c: Double) -> Bool { c.isFinite && c > 5 && c < 130 }

    /// Summary temperatures from the HID sensor list. Apple Silicon names its SoC die sensors
    /// "PMU tdie…"; drives "NAND…"; the battery "gas gauge battery".
    static func temperatureSummary(_ all: [TemperatureReading]) -> (cpuAverage: Double?, cpuMax: Double?, ssd: Double?, battery: Double?) {
        let die = all.filter { $0.name.lowercased().contains("tdie") }.map(\.celsius)
        let ssd = all.filter { $0.name.uppercased().hasPrefix("NAND") }.map(\.celsius).max()
        let battery = all.first { $0.name.lowercased().contains("battery") }?.celsius
        return (die.isEmpty ? nil : die.reduce(0, +) / Double(die.count), die.max(), ssd, battery)
    }

    /// 85 °C and up is warm for Apple Silicon under sustained load; 95 °C means it's throttling.
    static func temperatureLevel(_ c: Double?) -> SystemLevel {
        guard let c, c.isFinite else { return .normal }
        return c >= 95 ? .critical : c >= 85 ? .warning : .normal
    }

    /// GPU uses the same thresholds as the CPU.
    static func gpuLevel(_ p: Double?) -> SystemLevel {
        guard let p, p.isFinite else { return .normal }
        return p >= 90 ? .critical : p >= 70 ? .warning : .normal
    }

    /// NVMe SMART log page (512 bytes, NVMe 1.x section 5.10.1.2), little-endian.
    static func driveHealth(smart b: [UInt8], model: String?) -> DriveHealth? {
        guard b.count >= 176 else { return nil }
        func le(_ o: Int, _ n: Int) -> UInt64 { (0..<n).reduce(0) { $0 | UInt64(b[o + $1]) << (8 * UInt64($1)) } }
        // 128-bit counters: anything above 64 bits would be absurd, cap rather than overflow.
        func counter(_ o: Int) -> UInt64 { le(o + 8, 8) == 0 ? le(o, 8) : .max }
        let kelvin = Int(le(1, 2))
        let warning = Int(b[0]), spare = Int(b[3]), threshold = Int(b[4]), used = Int(b[5])
        let units: (UInt64) -> UInt64 = { $0.multipliedReportingOverflow(by: 512_000).overflow ? .max : $0 * 512_000 }
        let level: SystemLevel = warning != 0 || (threshold > 0 && spare < threshold) || used >= 100 ? .critical
                                : used >= 80 || counter(160) > 0 ? .warning : .normal
        return DriveHealth(model: model, level: level.name,
                           temperatureC: kelvin > 200 && kelvin < 400 ? kelvin - 273 : nil,
                           percentageUsed: used <= 255 ? used : nil,
                           availableSparePercent: spare <= 100 ? spare : nil,
                           availableSpareThresholdPercent: threshold <= 100 ? threshold : nil,
                           criticalWarning: warning, powerCycles: counter(112), powerOnHours: counter(128),
                           unsafeShutdowns: counter(144), mediaErrors: counter(160),
                           dataReadBytes: units(counter(32)), dataWrittenBytes: units(counter(48)))
    }

    /// SMC values are floats ("flt ") on Apple Silicon and fixed-point ("fpe2") on Intel.
    static func smcValue(type: String, bytes: [UInt8]) -> Double? {
        switch type {
        case "flt " where bytes.count == 4:
            let v = Double(Float(bitPattern: UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24))
            return v.isFinite ? v : nil
        case "fpe2" where bytes.count == 2:
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "ui8 " where bytes.count == 1:
            return Double(bytes[0])
        case "ui16" where bytes.count == 2:
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        default:
            return nil
        }
    }

    /// Wi-Fi band from the channel number.
    static func band(channel: Int?) -> Double? {
        guard let c = channel else { return nil }
        switch c {
        case 1...14: return 2.4
        case 32...177: return 5
        default: return nil
        }
    }

    /// Battery health = full-charge capacity ÷ design capacity.
    static func batteryHealth(maxCapacity: Int?, designCapacity: Int?) -> Double? {
        guard let m = maxCapacity, let d = designCapacity, d > 0, m > 0, m < d * 2 else { return nil }
        return min(100, Double(m) / Double(d) * 100)
    }

    /// `nettop -P -L 2 -d -x -J bytes_in,bytes_out` output: the second (delta) sample's
    /// "name.pid,in,out," lines → bytes per second over `seconds`.
    static func parseNettop(_ text: String, seconds: Double) -> [(pid: Int32, name: String, bytesPerSecond: Double)] {
        let blocks = text.components(separatedBy: ",bytes_in,bytes_out,")
        guard blocks.count >= 3, seconds > 0 else { return [] }
        return blocks[2].split(separator: "\n").compactMap { line in
            let parts = line.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count >= 3, let dot = parts[0].lastIndex(of: "."),
                  let pid = Int32(parts[0][parts[0].index(after: dot)...]), pid > 0,
                  let rx = Double(parts[1]), let tx = Double(parts[2]), rx >= 0, tx >= 0, (rx + tx).isFinite else { return nil }
            let total = (rx + tx) / seconds
            return total > 0 ? (pid, String(parts[0][..<dot]), total) : nil
        }
    }
}

// MARK: - Probes

enum HardwareProbe {
    /// Performance levels, fastest first: name ("Performance", "Efficiency", "Super", ...) and core count.
    static func perfLevels() -> [(name: String, count: Int)] {
        func int(_ n: String) -> Int? {
            var v: Int32 = 0
            var size = MemoryLayout<Int32>.size
            return sysctlbyname(n, &v, &size, nil, 0) == 0 ? Int(v) : nil
        }
        func string(_ n: String) -> String? {
            var size = 0
            guard sysctlbyname(n, nil, &size, nil, 0) == 0, size > 0, size < 256 else { return nil }
            var buf = [CChar](repeating: 0, count: size)
            return sysctlbyname(n, &buf, &size, nil, 0) == 0 ? String(cString: buf) : nil
        }
        let n = min(int("hw.nperflevels") ?? 0, 8)
        return (0..<n).compactMap { i in
            guard let name = string("hw.perflevel\(i).name"), let c = int("hw.perflevel\(i).logicalcpu"), c > 0 else { return nil }
            return (name, c)
        }
    }

    /// Cluster letter per logical CPU, from IODeviceTree:/cpus.
    static func coreTypes(count: Int) -> [String]? {
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != 0 else { return nil }
        defer { IOObjectRelease(cpus) }
        var iter: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        var entries: [(Int, String)] = []
        var cpu = IOIteratorNext(iter)
        while cpu != 0 {
            let id = (IORegistryEntryCreateCFProperty(cpu, "logical-cpu-id" as CFString, nil, 0)?.takeRetainedValue() as? NSNumber)?.intValue
            let cluster = (IORegistryEntryCreateCFProperty(cpu, "cluster-type" as CFString, nil, 0)?.takeRetainedValue() as? Data)
                .flatMap { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if let id, let cluster, !cluster.isEmpty { entries.append((id, cluster)) }
            IOObjectRelease(cpu)
            cpu = IOIteratorNext(iter)
        }
        return HardwareMath.coreTypes(entries, count: count)
    }

    static func gpu() -> GPUReading? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        let s = IOIteratorNext(iter)
        guard s != 0 else { return nil }
        defer { IOObjectRelease(s) }
        guard let stats = IORegistryEntryCreateCFProperty(s, "PerformanceStatistics" as CFString, nil, 0)?.takeRetainedValue() as? [String: Any] else { return nil }
        let model = IORegistryEntryCreateCFProperty(s, "model" as CFString, nil, 0)?.takeRetainedValue() as? String
        let cores = (IORegistryEntryCreateCFProperty(s, "gpu-core-count" as CFString, nil, 0)?.takeRetainedValue() as? NSNumber)?.intValue
        return HardwareMath.gpu(stats: stats, model: model, cores: cores)
    }

    // MARK: Temperatures (IOHIDEventSystem, looked up at run time)

    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatchingFn = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServicesFn = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEventFn = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloatFn = @convention(c) (AnyObject, Int32) -> Double

    private static let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
    private static func symbol<T>(_ name: String) -> T? { dlsym(iokit, name).map { unsafeBitCast($0, to: T.self) } }

    static func temperatures() -> [TemperatureReading] {
        guard let create: CreateFn = symbol("IOHIDEventSystemClientCreate"),
              let setMatching: SetMatchingFn = symbol("IOHIDEventSystemClientSetMatching"),
              let copyServices: CopyServicesFn = symbol("IOHIDEventSystemClientCopyServices"),
              let copyProperty: CopyPropertyFn = symbol("IOHIDServiceClientCopyProperty"),
              let copyEvent: CopyEventFn = symbol("IOHIDServiceClientCopyEvent"),
              let getFloat: GetFloatFn = symbol("IOHIDEventGetFloatValue"),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { return [] }
        // Usage page 0xff00 / usage 5 = temperature sensors; event type 15 = temperature.
        _ = setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        let services = (copyServices(client)?.takeRetainedValue() as? [AnyObject]) ?? []
        var out: [TemperatureReading] = []
        for s in services.prefix(200) {
            guard let name = copyProperty(s, "Product" as CFString)?.takeRetainedValue() as? String,
                  let event = copyEvent(s, 15, 0, 0)?.takeRetainedValue() else { continue }
            let c = getFloat(event, 15 << 16)
            if HardwareMath.validTemperature(c) { out.append(.init(name: name, celsius: (c * 10).rounded() / 10)) }
        }
        return out.sorted { $0.name < $1.name }
    }

    // MARK: Fans and power (AppleSMC)

    private struct SMCParam {
        struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
        struct PLimit { var version: UInt16 = 0, length: UInt16 = 0, cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
        struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0, dataAttributes: UInt8 = 0 }
        var key: UInt32 = 0
        var version = Version()
        var pLimit = PLimit()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var command: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    }

    final class SMC {
        private var conn: io_connect_t = 0

        init?() {
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
            guard service != 0 else { return nil }
            defer { IOObjectRelease(service) }
            guard IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return nil }
        }

        deinit { IOServiceClose(conn) }

        private func call(_ input: inout SMCParam) -> SMCParam? {
            var out = SMCParam()
            var size = MemoryLayout<SMCParam>.stride
            let kr = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<SMCParam>.stride, &out, &size)
            return kr == KERN_SUCCESS && out.result == 0 ? out : nil
        }

        func value(_ key: String) -> Double? {
            guard key.utf8.count == 4 else { return nil }
            let code = key.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            var info = SMCParam()
            info.key = code
            info.command = 9   // read key info
            guard let i = call(&info), i.keyInfo.dataSize > 0, i.keyInfo.dataSize <= 32 else { return nil }
            var read = SMCParam()
            read.key = code
            read.keyInfo.dataSize = i.keyInfo.dataSize
            read.command = 5   // read bytes
            guard let r = call(&read) else { return nil }
            let t = i.keyInfo.dataType
            let type = String(decoding: [UInt8(t >> 24 & 0xff), UInt8(t >> 16 & 0xff), UInt8(t >> 8 & 0xff), UInt8(t & 0xff)], as: UTF8.self)
            let bytes = withUnsafeBytes(of: r.bytes) { Array($0.prefix(Int(i.keyInfo.dataSize))) }
            return HardwareMath.smcValue(type: type, bytes: bytes)
        }
    }

    static func fansAndPower() -> (fans: [FanReading], systemWatts: Double?) {
        guard let smc = SMC() else { return ([], nil) }
        let count = min(Int(smc.value("FNum") ?? 0), 8)
        let fans = (0..<count).compactMap { i -> FanReading? in
            guard let rpm = smc.value("F\(i)Ac"), rpm.isFinite, rpm >= 0, rpm < 20_000 else { return nil }
            return FanReading(index: i, rpm: rpm.rounded(), minRpm: smc.value("F\(i)Mn")?.rounded(), maxRpm: smc.value("F\(i)Mx")?.rounded())
        }
        let watts = smc.value("PSTR").flatMap { $0.isFinite && $0 >= 0 && $0 < 2000 ? ($0 * 10).rounded() / 10 : nil }
        return (fans, watts)
    }

    // MARK: Drive health (NVMe SMART plug-in, public IOKit)

    static func driveHealth() -> [DriveHealth] {
        let userClientType = CFUUIDGetConstantUUIDWithBytes(nil, 0xAA, 0x0F, 0xA6, 0xF9, 0xC2, 0xD6, 0x45, 0x7F, 0xB1, 0x0B, 0x59, 0xA1, 0x32, 0x53, 0x29, 0x2F)
        let smartInterface = CFUUIDGetConstantUUIDWithBytes(nil, 0xCC, 0xD1, 0xDB, 0x19, 0xFD, 0x9A, 0x4D, 0xAF, 0xBF, 0x95, 0x12, 0x45, 0x4B, 0x23, 0x0A, 0xB6)
        let plugInInterface = CFUUIDGetConstantUUIDWithBytes(nil, 0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4, 0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IONVMeBlockStorageDevice"), &iter) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iter) }
        var out: [DriveHealth] = []
        var s = IOIteratorNext(iter)
        while s != 0, out.count < 8 {
            defer { IOObjectRelease(s); s = IOIteratorNext(iter) }
            guard (IORegistryEntryCreateCFProperty(s, "NVMe SMART Capable" as CFString, nil, 0)?.takeRetainedValue() as? Bool) == true else { continue }
            var model: String?
            var parent: io_registry_entry_t = 0
            if IORegistryEntryGetParentEntry(s, kIOServicePlane, &parent) == KERN_SUCCESS {
                model = (IORegistryEntryCreateCFProperty(parent, "Model Number" as CFString, nil, 0)?.takeRetainedValue() as? String)?
                    .trimmingCharacters(in: .whitespaces)
                IOObjectRelease(parent)
            }
            var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
            var score: Int32 = 0
            guard IOCreatePlugInInterfaceForService(s, userClientType, plugInInterface, &plugin, &score) == KERN_SUCCESS,
                  let plugin, let pluginTable = plugin.pointee else { continue }
            defer { IODestroyPlugInInterface(plugin) }
            var smart: LPVOID?
            guard pluginTable.pointee.QueryInterface(plugin, CFUUIDGetUUIDBytes(smartInterface), &smart) == 0, let smart else { continue }
            // IONVMeSMARTInterface (NVMeSMARTLibExternal.h): _reserved, QueryInterface, AddRef, Release,
            // version + revision (padded to 8 bytes), then SMARTReadData at byte 40.
            let table = smart.assumingMemoryBound(to: UnsafeRawPointer.self).pointee
            typealias ReadFn = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> IOReturn
            typealias ReleaseFn = @convention(c) (UnsafeMutableRawPointer) -> UInt32
            let read = unsafeBitCast(table.load(fromByteOffset: 40, as: UnsafeRawPointer.self), to: ReadFn.self)
            let release = unsafeBitCast(table.load(fromByteOffset: 24, as: UnsafeRawPointer.self), to: ReleaseFn.self)
            defer { _ = release(smart) }
            var buffer = [UInt8](repeating: 0, count: 512)
            guard buffer.withUnsafeMutableBytes({ read(smart, $0.baseAddress!) }) == kIOReturnSuccess else { continue }
            if let h = HardwareMath.driveHealth(smart: buffer, model: model) { out.append(h) }
        }
        return out
    }

    // MARK: Volumes, Wi-Fi, battery

    static func volumes() -> [VolumeReading] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeAvailableCapacityKey, .volumeIsInternalKey, .volumeIsRemovableKey,
                                      .volumeIsBrowsableKey, .volumeLocalizedFormatDescriptionKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.prefix(32).compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable != false,
                  let total = v.volumeTotalCapacity, total > 0 else { return nil }
            let isStartup = url.path == "/"
            let free = isStartup ? (v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0))
                                 : Int64(v.volumeAvailableCapacity ?? 0)
            return VolumeReading(name: v.volumeName ?? url.lastPathComponent, totalBytes: Int64(total), freeBytes: free,
                                 usedPercent: SystemMath.diskUsedPercent(total: Int64(total), available: free),
                                 fileSystem: v.volumeLocalizedFormatDescription, isInternal: v.volumeIsInternal,
                                 isRemovable: v.volumeIsRemovable, isStartup: isStartup)
        }
    }

    static func wifi() -> WiFiReading? {
        guard let iface = CWWiFiClient.shared().interface(), iface.powerOn(), let name = iface.interfaceName else { return nil }
        let rssi = iface.rssiValue(), noise = iface.noiseMeasurement()
        let channel = iface.wlanChannel()
        let band: Double?
        switch channel?.channelBand {
        case .band2GHz: band = 2.4
        case .band5GHz: band = 5
        case .band6GHz: band = 6
        default: band = HardwareMath.band(channel: channel?.channelNumber)
        }
        // Not associated: still report the interface so a reader knows Wi-Fi is on but idle.
        return WiFiReading(interface: name, ssid: iface.ssid(), rssiDbm: rssi == 0 ? nil : rssi, noiseDbm: noise == 0 ? nil : noise,
                           channel: channel?.channelNumber, bandGhz: band,
                           transmitRateMbps: iface.transmitRate() > 0 ? iface.transmitRate() : nil)
    }

    static func battery() -> BatteryReading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType, d[kIOPSIsPresentKey] as? Bool != false else { continue }
            let cur = d[kIOPSCurrentCapacityKey] as? Int, max = d[kIOPSMaxCapacityKey] as? Int
            let percent = cur.flatMap { c in max.flatMap { $0 > 0 ? Int((Double(c) / Double($0) * 100).rounded()) : nil } }
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            let minutes = (charging ? d[kIOPSTimeToFullChargeKey] : d[kIOPSTimeToEmptyKey]) as? Int
            var reading = BatteryReading(percent: percent, charging: charging,
                                         pluggedIn: d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                                         minutesRemaining: minutes.flatMap { $0 > 0 && $0 < 6000 ? $0 : nil })
            let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            if s != 0 {
                func prop(_ k: String) -> Int? { (IORegistryEntryCreateCFProperty(s, k as CFString, nil, 0)?.takeRetainedValue() as? NSNumber)?.intValue }
                reading.cycleCount = prop("CycleCount")
                reading.healthPercent = HardwareMath.batteryHealth(maxCapacity: prop("AppleRawMaxCapacity") ?? prop("NominalChargeCapacity"),
                                                                   designCapacity: prop("DesignCapacity"))
                reading.temperatureC = prop("Temperature").map { Double($0) / 100 }.flatMap { HardwareMath.validTemperature($0) ? $0 : nil }
                IOObjectRelease(s)
            }
            return reading
        }
        return nil
    }

    /// Processes using the network, measured over about a second by the built-in `nettop` (~5 s total).
    static func topNetwork(limit: Int) -> [ProcessUsage] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        p.arguments = ["-P", "-L", "2", "-s", "1", "-d", "-x", "-J", "bytes_in,bytes_out"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return HardwareMath.parseNettop(String(decoding: data, as: UTF8.self), seconds: 1)
            .sorted { $0.bytesPerSecond != $1.bytesPerSecond ? $0.bytesPerSecond > $1.bytesPerSecond : $0.pid < $1.pid }
            .prefix(max(1, min(limit, 30)))
            .map { ProcessUsage(pid: $0.pid, name: $0.name, value: $0.bytesPerSecond) }
    }
}
