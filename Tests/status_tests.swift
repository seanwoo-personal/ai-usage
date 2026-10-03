import Foundation

/// Saved status file, read-only commands and the MCP server. Uses temporary folders, fixed
/// readings and fake tools — never the real status file, processes or network.
enum StatusTests {
    static func sample(at date: Date, source: String = "app") -> StatusSnapshot {
        let host = StatusSnapshot.HostInfo(name: "Test Mac", model: "Mac16,10", chip: "Apple M4", cpuCores: 10,
                                           performanceCores: 4, efficiencyCores: 6, memoryBytes: 24 << 30,
                                           macosVersion: "26.0.0", uptimeSeconds: 3600)
        let system = StatusSnapshot.system(
            cpu: .init(usagePercent: 31.23456, level: "normal", userPercent: 20, systemPercent: 11, idlePercent: 69,
                       coresPercent: [50.123, nil], loadAverage: [1.23456, 2, 3]),
            memory: nil, memoryPercent: 81, pressureFree: 15, pressure: 1, swap: (0, 0),
            disk: (1000, 330), diskPercent: 67, diskRead: 1234.5678, diskWrite: nil, diskTotals: (10, 20),
            download: 2048.4, upload: nil, netTotals: .init(sent: 1, received: 2), interface: "Ethernet", localIP: "10.0.0.2",
            history: .init(intervalSeconds: 1, cpuPercent: [1.26, 2], memoryPercent: [], diskReadBytesPerSecond: [],
                           diskWriteBytesPerSecond: [], downloadBytesPerSecond: [3.7], uploadBytesPerSecond: []))
        let usage = StatusSnapshot.aiUsage(
            provider: .claude, connection: .cli,
            snapshot: ProviderSnapshot(provider: .claude, windows: [
                UsageWindow(kind: .session, usedPercent: 40, resetsAt: date.addingTimeInterval(3600), windowMinutes: 300),
                UsageWindow(kind: .weekly, usedPercent: 90, resetsAt: date.addingTimeInterval(-60), windowMinutes: 10_080),
                UsageWindow(kind: .weekly, usedPercent: .nan, resetsAt: nil, windowMinutes: nil)],
                plan: "max", source: .live, fetchedAt: date),
            error: nil, now: date)
        return StatusSnapshot(generatedAt: date, source: source, appVersion: "9.9.9", host: host, system: system, aiUsage: [usage])
    }

    static func run() {
        print("Saved status and MCP")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let s = sample(at: now)

        // Levels and usage as the app shows them
        check(s.system.memory.level == "warning", "status: RAM level from free memory (15% free → warning)")
        check(s.aiUsage?.first?.windows.map(\.kind) == ["session_5h", "weekly", "weekly"], "status: usage windows named for readers")
        check(s.aiUsage?.first?.windows[1].usedPercent == 0 && s.aiUsage?.first?.windows[1].resetsAt == nil,
              "status: a window whose reset passed counts as fresh, like the app")
        check(s.aiUsage?.first?.windows[2].usedPercent == nil, "status: a non-numeric usage value is left out, not NaN")

        // Encoding: snake_case, ISO dates, rounded, no secrets, round trip
        let r = s.rounded()
        check(r.system.cpu.usagePercent == 31.2 && r.system.cpu.loadAverage?.first == 1.23 && r.system.cpu.coresPercent == [50.1, nil]
              && r.system.disk.readBytesPerSecond == 1235 && r.system.history?.cpuPercent == [1.3, 2],
              "status: percentages rounded to 0.1, rates to whole bytes")
        let data = (try? StatusSnapshot.encoder().encode(r)) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        check(text.contains("\"schema_version\":1") && text.contains("\"usage_percent\"") && text.contains("2027-01-15T08:00:00Z"),
              "status JSON: snake_case keys and ISO 8601 dates")
        check(!text.lowercased().contains("token") && !text.contains("@"), "status JSON: no tokens or e-mail addresses")
        check(StatusSnapshot.decode(data) == r, "status JSON: reads back exactly")
        check(StatusSnapshot.decode(Data("{\"schema_version\":2}".utf8)) == nil && StatusSnapshot.decode(Data("nope".utf8)) == nil,
              "status JSON: other schema versions and junk are ignored")

        // File: atomic, private, fresh/stale
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aiusage-status-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sub/status.json")
        do {
            try StatusFile.write(s, to: url)
            let mode = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1
            let dirMode = (try? FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? Int) ?? -1
            check(mode == 0o600 && dirMode == 0o700, "status file: readable by this user only (0600, folder 0700)")
            check(StatusFile.read(at: url) == r, "status file: written rounded and read back")
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
            check(leftovers == ["status.json"], "status file: no temporary files left behind")
        } catch { check(false, "status file: write failed (\(error))") }
        check(StatusFile.read(at: dir.appendingPathComponent("missing.json")) == nil, "status file: missing → nil")
        check(StatusFile.isFresh(s, now: now.addingTimeInterval(10)) && !StatusFile.isFresh(s, now: now.addingTimeInterval(31)),
              "status file: fresh for 30 seconds")
        check(!StatusFile.isFresh(s, now: now.addingTimeInterval(-3600)), "status file: dated far in the future → not trusted")

        // Command: saved vs measured
        var measured = 0
        let measure = { () -> StatusSnapshot.SystemStatus in measured += 1; return sample(at: now).system }
        let host = { sample(at: now).host }
        let fresh = StatusCLI.currentStatus(includeHistory: false, saved: s, now: now.addingTimeInterval(5), measure: measure, host: host)
        check(fresh.source == "app" && measured == 0 && fresh.system.history == nil,
              "status command: the app's recent file is used as is (history only when asked)")
        let stale = StatusCLI.currentStatus(saved: s, now: now.addingTimeInterval(600), measure: measure, host: host)
        check(stale.source == "live" && measured == 1 && stale.aiUsage == s.rounded().aiUsage,
              "status command: app not running → measures now, keeps the last saved AI usage")
        let none = StatusCLI.currentStatus(saved: nil, now: now, measure: measure, host: host)
        check(none.source == "live" && none.aiUsage == nil, "status command: never saved → measured, AI usage unknown")
        check(StatusCLI.run(["AIUsage"]) == nil && StatusCLI.run(["AIUsage", "-psn_0_1234"]) == nil
              && StatusCLI.run(["AIUsage", "-onboarded", "NO"]) == nil && StatusCLI.run(["AIUsage", "--render-preview", "x"]) == nil,
              "commands: app launch arguments still start the app")
        check(StatusCLI.uptime(3 * 86_400 + 4 * 3600) == "3d 4h" && StatusCLI.uptime(-5) == "0m", "commands: uptime text")

        // MCP protocol
        var topCalls: [(StatusCLI.TopKind, Int)] = []
        let server = MCPServer(status: { h in var x = s; if !h { x.system.history = nil }; return x },
                               top: { by, n in topCalls.append((by, n)); return [ProcessUsage(pid: 7, name: "Safari", value: 12.34)] },
                               version: "9.9.9")
        func reply(_ line: String) -> [String: Any]? {
            server.handle(line).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
        func result(_ line: String) -> [String: Any]? { reply(line)?["result"] as? [String: Any] }
        func toolText(_ r: [String: Any]?) -> String { ((r?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "" }

        let initialize = result(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        check(initialize?["protocolVersion"] as? String == "2025-03-26" && (initialize?["capabilities"] as? [String: Any])?["tools"] != nil
              && (initialize?["serverInfo"] as? [String: Any])?["name"] as? String == "ai-usage",
              "MCP initialize: echoes a supported protocol version, offers tools")
        let future = result(#"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#)
        check(future?["protocolVersion"] as? String == MCPServer.supportedVersions[0], "MCP initialize: unknown version → our latest")
        check(server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil && server.handle("   ") == nil,
              "MCP: notifications and blank lines get no reply")
        let tools = (result(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)?["tools"] as? [[String: Any]]) ?? []
        check(Set(tools.compactMap { $0["name"] as? String }) == ["get_status", "get_ai_usage", "get_top_processes"]
              && tools.allSatisfy { (($0["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool) == true },
              "MCP tools/list: three tools, all marked read-only")
        let status = result(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_status","arguments":{}}}"#)
        let statusJSON = toolText(status)
        check(status?["isError"] as? Bool == false && statusJSON.contains("\"usage_percent\"") && !statusJSON.contains("\"history\""),
              "MCP get_status: status JSON without history by default")
        check(toolText(result(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_status","arguments":{"include_history":true}}}"#)).contains("\"history\""),
              "MCP get_status: history when asked")
        check(toolText(result(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"get_ai_usage"}}"#)).contains("session_5h"),
              "MCP get_ai_usage: Claude/Codex windows")
        let top = result(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"get_top_processes","arguments":{"by":"memory","limit":3}}}"#)
        check(toolText(top).contains("Safari") && toolText(top).contains("\"unit\" : \"bytes\"") && topCalls.last.map { $0.0 == .memory && $0.1 == 3 } == true,
              "MCP get_top_processes: kind and limit passed through, unit stated")
        for (args, name) in [(#"{"by":"gpu"}"#, "unknown kind"), (#"{"limit":0}"#, "limit 0"), (#"{"limit":2.5}"#, "fractional limit"),
                             (#"{"limit":"5"}"#, "text limit"), (#"{"limit":1e300}"#, "huge limit"), (#"{"limit":true}"#, "boolean limit"), (#"{"limit":-1e300}"#, "huge negative limit")] {
            let r = result(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"get_top_processes","arguments":"# + args + "}}")
            check(r?["isError"] as? Bool == true, "MCP get_top_processes: \(name) → tool error, no crash")
        }
        check(result(#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"get_status","arguments":{"include_history":"yes"}}}"#)?["isError"] as? Bool == true,
              "MCP get_status: non-boolean include_history → tool error")
        func errorCode(_ line: String) -> Int? { (reply(line)?["error"] as? [String: Any])?["code"] as? Int }
        check(errorCode(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"kill_process"}}"#) == -32602, "MCP: unknown tool → invalid params")
        check(errorCode(#"{"jsonrpc":"2.0","id":10,"method":"resources/list"}"#) == -32601, "MCP: unknown method → method not found")
        check(errorCode("{not json") == -32700 && errorCode("[1,2]") == -32700, "MCP: malformed input → parse error")
        check(errorCode(#"{"jsonrpc":"2.0","id":11}"#) == -32600, "MCP: request without a method → invalid request")
        check(result(#"{"jsonrpc":"2.0","id":12,"method":"ping"}"#) != nil, "MCP: ping")
        check(reply(#"{"jsonrpc":"2.0","id":13,"method":"ping"}"#)?["id"] as? Int == 13
              && reply(#"{"jsonrpc":"2.0","id":"x","method":"ping"}"#)?["id"] as? String == "x", "MCP: replies carry the request id")
    }
}
