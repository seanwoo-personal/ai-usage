import Foundation

/// Read-only commands built into the app's executable, for people, scripts and AI tools —
/// on this Mac or over SSH (`ssh mac "/Applications/AI Usage.app/Contents/MacOS/AIUsage" mcp`).
/// They never open a window, change settings, touch credentials or make network requests.
enum StatusCLI {
    static let usage = """
    AI Usage — read this Mac's status (read-only)

      AIUsage status [--json]        CPU, memory, disk, network and Claude/Codex usage
      AIUsage top [cpu|memory|disk]  busiest processes (default: cpu)
      AIUsage mcp                    MCP server on stdin/stdout, for AI tools

    The app saves its status every 5 seconds. If it isn't running, system values are
    measured on the spot and Claude/Codex usage is the last saved value (or none).
    """

    /// Runs a command and returns its exit code, or nil if `args` isn't a command (start the app).
    static func run(_ args: [String]) -> Int32? {
        guard args.count >= 2 else { return nil }
        let rest = Array(args.dropFirst(2))
        switch args[1] {
        case "status":
            let s = currentStatus(includeHistory: rest.contains("--history"))
            if rest.contains("--json") {
                print(String(decoding: (try? StatusSnapshot.encoder(pretty: true).encode(s)) ?? Data(), as: UTF8.self))
            } else {
                print(summary(s))
            }
            return 0
        case "top":
            let by = TopKind(rawValue: rest.first ?? "cpu") ?? .cpu
            for p in topProcesses(by: by, limit: 10) {
                print(String(format: "%6d  %-12@  %@", p.pid, format(p.value, by: by) as NSString, p.name as NSString))
            }
            return 0
        case "mcp":
            MCPServer.live().serve()
            return 0
        case "help", "--help", "-h":
            print(usage)
            return 0
        default:
            return nil   // Unknown words (and macOS's own -psn / -NS... arguments) start the app as usual.
        }
    }

    /// The saved status if the app saved it recently; otherwise a fresh measurement
    /// with the last saved Claude/Codex usage.
    static func currentStatus(includeHistory: Bool = true, saved: StatusSnapshot? = StatusFile.read(), now: Date = Date(),
                              measure: () -> StatusSnapshot.SystemStatus = { StatusSnapshot.system(from: StatusSnapshot.measure()) },
                              host: () -> StatusSnapshot.HostInfo = SystemProbe.host) -> StatusSnapshot {
        var s: StatusSnapshot
        if let saved, StatusFile.isFresh(saved, now: now) {
            s = saved
        } else {
            s = StatusSnapshot(generatedAt: now, source: "live", appVersion: appVersion, host: host(),
                               system: measure(), aiUsage: saved?.aiUsage)
        }
        if !includeHistory { s.system.history = nil }
        return s.rounded()
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    // MARK: Top processes (measured on demand)

    enum TopKind: String, CaseIterable { case cpu, memory, disk }

    static func topProcesses(by: TopKind, limit: Int) -> [ProcessUsage] {
        let n = max(1, min(limit, 30))
        switch by {
        case .cpu: return SystemProbe.topByPS("pcpu", sortFlag: "-r", valueScale: 1, limit: n)
        case .memory: return SystemProbe.topByPS("rss", sortFlag: "-m", valueScale: 1024, limit: n)
        case .disk:
            let a = SystemProbe.diskBytesByProcess(), start = Date()
            Thread.sleep(forTimeInterval: 1)
            let b = SystemProbe.diskBytesByProcess()
            return SystemMath.topDiskProcesses(from: a, to: b, seconds: Date().timeIntervalSince(start), limit: n)
        }
    }

    static func format(_ v: Double, by: TopKind) -> String {
        switch by {
        case .cpu: return String(format: "%.1f%%", v)
        case .memory: return SystemMath.bytesText(v)
        case .disk: return SystemMath.rateText(v)
        }
    }

    // MARK: Human-readable summary

    /// "3d 4h" / "5h 12m" / "42m" (English, like the rest of the command output).
    static func uptime(_ seconds: Int) -> String {
        let m = max(0, seconds) / 60, d = m / 1440, h = (m % 1440) / 60
        return d > 0 ? "\(d)d \(h)h" : h > 0 ? "\(h)h \(m % 60)m" : "\(m % 60)m"
    }

    static func summary(_ s: StatusSnapshot) -> String {
        let sys = s.system
        func pct(_ v: Double?) -> String { SystemMath.percentText(v) }
        func flag(_ level: String) -> String { level == "normal" ? "" : " [\(level)]" }
        var lines = [
            "\(s.host.name) · \(s.host.chip ?? s.host.model ?? "Mac") · macOS \(s.host.macosVersion) · up \(uptime(s.host.uptimeSeconds))",
            "CPU     \(pct(sys.cpu.usagePercent))\(flag(sys.cpu.level))" + (sys.cpu.loadAverage.map { "   load " + $0.map { String(format: "%.2f", $0) }.joined(separator: " ") } ?? ""),
            "Memory  \(pct(sys.memory.usedPercent))\(flag(sys.memory.level))   \(SystemMath.bytesText(sys.memory.usedBytes.map { Double($0) })) / \(SystemMath.bytesText(Double(sys.memory.totalBytes)))"
                + (sys.memory.pressureFreePercent.map { "   \($0)% free" } ?? ""),
            "Disk    \(pct(sys.disk.usedPercent))\(flag(sys.disk.level))   \(SystemMath.bytesText(sys.disk.freeBytes.map { Double($0) })) free",
            "Network ↓ \(SystemMath.rateText(sys.network.downloadBytesPerSecond))  ↑ \(SystemMath.rateText(sys.network.uploadBytesPerSecond))"
                + (sys.network.interface.map { "   \($0)" } ?? "") + (sys.network.localIp.map { " \($0)" } ?? ""),
        ]
        for u in s.aiUsage ?? [] {
            let windows = u.windows.map { w in
                "\(w.label) \(w.remainingPercent.map { "\(Int($0.rounded()))% left" } ?? "?")"
                    + (w.resetsAt.map { ", resets " + ISO8601DateFormatter().string(from: $0) } ?? "")
            }
            lines.append("\(u.provider.capitalized)  " + (windows.isEmpty ? (u.error ?? "no data") : windows.joined(separator: " · ")))
        }
        lines.append(s.source == "app" ? "(saved by the app \(Int(Date().timeIntervalSince(s.generatedAt)))s ago)"
                                       : "(measured now; the app isn't running" + (s.aiUsage == nil ? ")" : ", AI usage is the last saved value)"))
        return lines.joined(separator: "\n")
    }
}

/// A minimal MCP server (JSON-RPC 2.0 over newline-delimited stdin/stdout) with read-only tools.
struct MCPServer {
    static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    /// Returns the JSON text for a tool; throws `ToolError` for bad arguments.
    var status: (_ includeHistory: Bool) -> StatusSnapshot
    var top: (_ by: StatusCLI.TopKind, _ limit: Int) -> [ProcessUsage]
    var version: String

    struct ToolError: Error { let message: String }

    static func live() -> MCPServer {
        MCPServer(status: { StatusCLI.currentStatus(includeHistory: $0) },
                  top: { StatusCLI.topProcesses(by: $0, limit: $1) }, version: StatusCLI.appVersion)
    }

    func serve() {
        setvbuf(stdout, nil, _IOLBF, 0)
        while let line = readLine(strippingNewline: true) {
            guard let reply = handle(line) else { continue }
            FileHandle.standardOutput.write(Data((reply + "\n").utf8))
        }
    }

    static let tools: [[String: Any]] = [
        ["name": "get_status",
         "title": "Mac status",
         "description": "This Mac's current status: host info, CPU, memory, disk and network (with normal/warning/critical levels) and Claude/Codex usage limits (percent left, reset times). Read-only.",
         "inputSchema": ["type": "object", "properties": [
            "include_history": ["type": "boolean", "description": "Also return the last ~2 minutes of samples per metric. Default false."]],
            "additionalProperties": false],
         "annotations": ["readOnlyHint": true, "openWorldHint": false]],
        ["name": "get_ai_usage",
         "title": "Claude / Codex usage",
         "description": "Claude and Codex usage limits on this Mac: 5-hour and weekly windows, percent used/left, reset times, last fetch time and any error. Read-only.",
         "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
         "annotations": ["readOnlyHint": true, "openWorldHint": false]],
        ["name": "get_top_processes",
         "title": "Busiest processes",
         "description": "Processes using the most CPU (%), memory (bytes) or disk (bytes per second, measured over 1 second) on this Mac. Read-only.",
         "inputSchema": ["type": "object", "properties": [
            "by": ["type": "string", "enum": ["cpu", "memory", "disk"], "description": "Default cpu."],
            "limit": ["type": "integer", "minimum": 1, "maximum": 30, "description": "Default 10."]],
            "additionalProperties": false],
         "annotations": ["readOnlyHint": true, "openWorldHint": false]],
    ]

    /// Handles one JSON-RPC message; nil for notifications (no reply).
    func handle(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] else {
            return Self.error(id: NSNull(), code: -32700, message: "Parse error")
        }
        guard let method = obj["method"] as? String else {
            return obj["id"] == nil ? nil : Self.error(id: obj["id"]!, code: -32600, message: "Invalid request")
        }
        guard let id = obj["id"], id is String || id is NSNumber else { return nil }   // notification
        let params = obj["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            return Self.result(id: id, [
                "protocolVersion": Self.supportedVersions.contains(asked) ? asked : Self.supportedVersions[0],
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "ai-usage", "title": "AI Usage", "version": version],
                "instructions": "Read-only status of the Mac this server runs on. Call get_status for an overview; levels warning/critical mean the Mac is under strain. Run one server per Mac (e.g. over SSH) to watch several.",
            ])
        case "ping":
            return Self.result(id: id, [String: Any]())
        case "tools/list":
            return Self.result(id: id, ["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            guard Self.tools.contains(where: { $0["name"] as? String == name }) else {
                return Self.error(id: id, code: -32602, message: "Unknown tool: \(name)")
            }
            do {
                return Self.result(id: id, ["content": [["type": "text", "text": try call(name, args)]], "isError": false])
            } catch let e as ToolError {
                return Self.result(id: id, ["content": [["type": "text", "text": e.message]], "isError": true])
            } catch {
                return Self.result(id: id, ["content": [["type": "text", "text": "\(error)"]], "isError": true])
            }
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    func call(_ name: String, _ args: [String: Any]) throws -> String {
        let enc = StatusSnapshot.encoder(pretty: true)
        func text<T: Encodable>(_ v: T) throws -> String { String(decoding: try enc.encode(v), as: UTF8.self) }
        switch name {
        case "get_status":
            if let h = args["include_history"], !(h is Bool) { throw ToolError(message: "include_history must be true or false") }
            return try text(status(args["include_history"] as? Bool ?? false))
        case "get_ai_usage":
            let s = status(false)
            struct Usage: Encodable { let host: String; let generatedAt: Date; let aiUsage: [StatusSnapshot.AIUsageStatus]?; let note: String? }
            return try text(Usage(host: s.host.name, generatedAt: s.generatedAt, aiUsage: s.aiUsage,
                                  note: s.aiUsage == nil ? "AI Usage has not saved any usage on this Mac yet (is the app running and connected?)" : nil))
        case "get_top_processes":
            let byText = args["by"] as? String ?? "cpu"
            guard let by = StatusCLI.TopKind(rawValue: byText) else { throw ToolError(message: "by must be cpu, memory or disk") }
            var limit = 10
            if let l = args["limit"] {
                // Range-check as a Double before converting: Int(1e300) would crash. JSON true is an NSNumber too.
                guard let num = l as? NSNumber, CFGetTypeID(num) != CFBooleanGetTypeID(),
                      case let n = num.doubleValue, n.isFinite, n == n.rounded(), n >= 1, n <= 30 else {
                    throw ToolError(message: "limit must be a whole number from 1 to 30")
                }
                limit = Int(n)
            }
            struct Proc: Encodable { let pid: Int32; let name: String; let value: Double; let display: String }
            struct Top: Encodable { let by: String; let unit: String; let processes: [Proc] }
            let unit = by == .cpu ? "percent" : by == .memory ? "bytes" : "bytes_per_second"
            return try text(Top(by: by.rawValue, unit: unit, processes: top(by, limit).map {
                Proc(pid: $0.pid, name: $0.name, value: $0.value, display: StatusCLI.format($0.value, by: by))
            }))
        default:
            throw ToolError(message: "Unknown tool: \(name)")
        }
    }

    private static func result(id: Any, _ result: Any) -> String {
        json(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func error(id: Any, code: Int, message: String) -> String {
        json(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private static func json(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}
