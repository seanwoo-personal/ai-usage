// Regression tests for defects found in v1.1.2 (7452ccf).
// Inputs that could crash the app run in a child process ("probe"), so one crash
// is reported as a failure instead of killing the whole test run.
import AppKit

enum Regression {
    // MARK: Crash probes (run in a child process)

    /// Each probe must finish normally and print "ok". Name → body.
    @MainActor static let probes: [(String, @MainActor () -> Bool)] = [
        ("Parse.int(NaN) → nil", { Parse.int(Double.nan) == nil }),
        ("Parse.int(+inf) → nil", { Parse.int(Double.infinity) == nil }),
        ("Parse.int(-inf) → nil", { Parse.int(-Double.infinity) == nil }),
        ("Parse.int(\"1e309\") → nil", { Parse.int("1e309") == nil }),
        ("Parse.int(1e300) → nil", { Parse.int(1e300) == nil }),
        ("Parse.int(\"9223372036854775807\") → Int.max", { Parse.int("9223372036854775807") == Int.max }),
        ("Parse.int(\"9223372036854775808\") → nil", { Parse.int("9223372036854775808") == nil }),
        ("Parse.int(\"-9223372036854775808\") → Int.min", { Parse.int("-9223372036854775808") == Int.min }),
        ("Parse.date(1e300) → nil", { Parse.date(1e300) == nil }),
        ("Parse.date(NaN) → nil", { Parse.date(Double.nan) == nil }),
        ("dayHour(1e300) doesn't crash", { !StatusImage.dayHour(1e300).isEmpty }),
        ("dayHour(+inf) doesn't crash", { !StatusImage.dayHour(.infinity).isEmpty }),
        ("dayHour(NaN) doesn't crash", { !StatusImage.dayHour(.nan).isEmpty }),
        ("L.countdown(1e300) doesn't crash", { !L.countdown(1e300).isEmpty }),
        ("L.compact(-inf) doesn't crash", { !L.compact(-.infinity).isEmpty }),
        ("L.ago(far future) doesn't crash", { !L.ago(Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 1e300)).isEmpty }),
        ("menu bar with NaN usage (used mode) doesn't crash", {
            let (s, st) = Regression.isolatedStore()
            s.showRemaining = false
            st.testInject(.claude, Regression.snap([UsageWindow(kind: .weekly, usedPercent: .nan, resetsAt: Date().addingTimeInterval(3600), windowMinutes: 10_080)]))
            return !StatusImage.blocks(store: st, settings: s).isEmpty
        }),
        ("menu bar with 1e300 usage doesn't crash", {
            let (s, st) = Regression.isolatedStore()
            s.showRemaining = false
            st.testInject(.claude, Regression.snap([UsageWindow(kind: .weekly, usedPercent: 1e300, resetsAt: Date().addingTimeInterval(3600), windowMinutes: 10_080)]))
            return !StatusImage.blocks(store: st, settings: s).isEmpty
        }),
        ("menu bar with a reset date far in the future doesn't crash", {
            let (s, st) = Regression.isolatedStore()
            st.testInject(.claude, Regression.snap([UsageWindow(kind: .weekly, usedPercent: 10, resetsAt: Date(timeIntervalSince1970: 1e15), windowMinutes: 10_080)]))
            return !StatusImage.blocks(store: st, settings: s).isEmpty
        }),
        ("refreshMinutes = Int.max: start() doesn't crash", {
            let (s, st) = Regression.isolatedStore()
            s.refreshMinutes = Int.max
            st.start()
            return true
        }),
    ]

    static func runProbe(_ name: String) -> Never {
        let ok = MainActor.assumeIsolated { probes.first { $0.0 == name }.map { $0.1() } ?? false }
        print(ok ? "ok" : "wrong-result")
        exit(0)
    }

    /// Runs every probe in its own child process.
    static func runProbes() {
        print("Crash-prone inputs (each in a separate process)")
        let names = MainActor.assumeIsolated { probes.map(\.0) }
        for name in names {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            p.arguments = ["probe", name]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { check(false, "\(name) (couldn't start probe)"); continue }
            p.waitUntilExit()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if p.terminationReason == .uncaughtSignal || p.terminationStatus != 0 {
                check(false, "\(name)  [CRASHED: signal/exit \(p.terminationStatus)]")
            } else {
                check(text.contains("ok"), name + (text.contains("ok") ? "" : "  [wrong result]"))
            }
        }
    }

    // MARK: In-process regression tests (no crash risk)

    @MainActor static func run() {
        runProbes()

        print("Input validation")
        check(Parse.double(true) == nil, "Bool true is not a usage number")
        check(Parse.double(false) == nil, "Bool false is not a usage number")
        check(Parse.double("") == nil, "empty string → nil")
        check(Parse.double(NSNull()) == nil, "null → nil")
        check(Parse.double(42) == 42 && Parse.double("12.5") == 12.5, "normal numbers still parse")
        check(Parse.int("15") == 15 && Parse.int(15.0) == 15, "normal integers still parse")
        if let json = try? JSONSerialization.jsonObject(with: Data(#"{"used_percent": true}"#.utf8)) as? [String: Any] {
            check(Parse.double(json["used_percent"]) == nil, "JSON true in used_percent is rejected")
        }
        let codexBool = #"{"rate_limit":{"primary_window":{"used_percent":true,"limit_window_seconds":604800,"reset_after_seconds":100}}}"#
        check(CodexProvider.parseLive(Data(codexBool.utf8)) == nil, "Codex window with used_percent=true is rejected")

        print("Menu bar: 'both' with only a 5-hour window")
        do {
            let (s, st) = isolatedStore()
            st.testInject(.claude, snap([UsageWindow(kind: .session, usedPercent: 40, resetsAt: Date().addingTimeInterval(3600), windowMinutes: 300)]))
            s.barModes = [.claude: .both, .codex: .weekly]
            let b = StatusImage.blocks(store: st, settings: s).first
            check(b?.equalLines == false && b?.bottom == "60%", "shows the one real window, no invented 7d line (got \(b.map { "\($0.top) / \($0.bottom)" } ?? "nil"))")
        }

        print("Codex session logs (synthetic files only)")
        codexLogTests()
    }

    @MainActor static func runAsync() async { await StoreTests.run(); CredentialTests.run(); OriginTests.run(); UpdaterTests.run(); SystemTests.run() }

    // MARK: Codex log fixtures

    @MainActor static func codexLogTests() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("aiusage-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let savedHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        setenv("CODEX_HOME", root.path, 1)
        defer { if let savedHome { setenv("CODEX_HOME", savedHome, 1) } else { unsetenv("CODEX_HOME") } }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func line(used: Double, at: Date, timestamp: String? = nil) -> String {
            let ts = timestamp ?? iso.string(from: at)
            let reset = Int(at.timeIntervalSince1970) + 5 * 86_400
            return #"{"timestamp":"\#(ts)","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":\#(used),"window_minutes":10080,"resets_at":\#(reset)}}}}"#
        }
        func dayDir(_ daysAgo: Int) -> URL {
            let d = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
            let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
            return root.appendingPathComponent(String(format: "sessions/%04d/%02d/%02d", c.year!, c.month!, c.day!))
        }
        func write(_ dir: URL, _ name: String, _ text: String, mtime: Date) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(name)
            try? Data(text.utf8).write(to: url)
            try? fm.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        }
        func reset() { try? fm.removeItem(at: root.appendingPathComponent("sessions")) }
        let now = Date()

        // (a) newest event wins, not newest file
        reset()
        write(dayDir(0), "rollout-a.jsonl", line(used: 80, at: now.addingTimeInterval(-60)) + "\n", mtime: now.addingTimeInterval(-600))
        write(dayDir(1), "rollout-b.jsonl", line(used: 10, at: now.addingTimeInterval(-86_400)) + "\n", mtime: now)
        let a = CodexProvider().latestFromLogs()?.windows.first?.usedPercent
        check(a == 80, "picks the newest event (80%), not the most recently touched file (got \(a.map { "\($0)" } ?? "nil"))")

        // (b) 1 MB tail starting in the middle of a Korean character
        reset()
        var big = ""
        let filler = #"{"timestamp":"x","type":"response_item","payload":{"text":"가나다라마바사아자차카타파하"}}"#
        while big.utf8.count < 1_100_000 { big += filler + "\n" }
        let last = line(used: 55, at: now.addingTimeInterval(-30)) + "\n"
        // Shift so the 1 MB boundary falls inside a 3-byte Hangul character.
        // Padding after the filler moves the 1 MB boundary; pick one that lands on a UTF-8 continuation byte.
        var text = ""
        for pad in 0..<64 {
            let candidate = big + String(repeating: "a", count: pad) + "\n" + last
            let bytes = Array(candidate.utf8)
            if (bytes[bytes.count - 1_000_000] & 0xC0) == 0x80 { text = candidate; break }
        }
        check(!text.isEmpty, "fixture: 1 MB boundary really falls inside a multi-byte character")
        write(dayDir(0), "rollout-big.jsonl", text, mtime: now)
        let b = CodexProvider().latestFromLogs()?.windows.first?.usedPercent
        check(b == 55, "reads the last event even when the 1 MB tail starts mid-character (got \(b.map { "\($0)" } ?? "nil"))")

        // (c) resumed old conversation: 9-day-old folder, fresh file and fresh event
        reset()
        write(dayDir(9), "rollout-old.jsonl", line(used: 33, at: now.addingTimeInterval(-120)) + "\n", mtime: now)
        let c = CodexProvider().latestFromLogs()?.windows.first?.usedPercent
        check(c == 33, "finds a fresh event in a resumed conversation's old folder (got \(c.map { "\($0)" } ?? "nil"))")

        // (d) broken timestamp is not treated as "now"
        reset()
        write(dayDir(0), "rollout-d.jsonl",
              line(used: 20, at: now.addingTimeInterval(-3600)) + "\n" + line(used: 99, at: now, timestamp: "broken") + "\n", mtime: now)
        let d = CodexProvider().latestFromLogs()
        check(d?.windows.first?.usedPercent == 20, "an event with a broken timestamp is skipped (got \(d?.windows.first.map { "\($0.usedPercent)" } ?? "nil"))")

        // (e) CRLF, no trailing newline, a corrupt line before a good one
        reset()
        write(dayDir(0), "rollout-e.jsonl",
              line(used: 5, at: now.addingTimeInterval(-500)) + "\r\n{broken json\r\n" + line(used: 44, at: now.addingTimeInterval(-10)), mtime: now)
        let e = CodexProvider().latestFromLogs()?.windows.first?.usedPercent
        check(e == 44, "handles CRLF, a corrupt line and a last line without newline (got \(e.map { "\($0)" } ?? "nil"))")
    }

    // MARK: Helpers

    /// A store whose settings live in a throwaway defaults domain (never the app's real settings).
    @MainActor static func isolatedStore() -> (AppSettings, UsageStore) {
        let s = AppSettings.forTesting()
        return (s, UsageStore(settings: s))
    }

    static func snap(_ windows: [UsageWindow], provider: Provider = .claude) -> ProviderSnapshot {
        ProviderSnapshot(provider: provider, windows: windows, plan: nil, source: .live, fetchedAt: Date())
    }
}
