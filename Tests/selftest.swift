// Self-test for parsing / formatting / menu bar logic.
// Run: ./scripts/selftest.sh   (compiles the app sources without main.swift plus this file)
import AppKit

var failures = 0
func check(_ cond: Bool, _ name: String, file: String = #file, line: Int = #line) {
    if cond { print("  ✓ \(name)") } else { failures += 1; print("  ✗ \(name)  (line \(line))") }
}

@main
struct SelfTest {
    @MainActor static func main() async {
        print("Parse.date")
        let d1 = Parse.date("2026-10-04T14:34:56.123456+00:00")
        check(d1 == Date(timeIntervalSince1970: 1_791_124_496), "ISO-8601 with microseconds + offset")
        check(Parse.date("2026-10-04T14:34:56Z") == Date(timeIntervalSince1970: 1_791_124_496), "ISO-8601 Z")
        check(Parse.date(1_791_124_477) == Date(timeIntervalSince1970: 1_791_124_477), "epoch seconds")
        check(Parse.date(1_791_124_477_000.0) == Date(timeIntervalSince1970: 1_791_124_477), "epoch milliseconds")
        check(Parse.date("") == nil && Parse.date(nil) == nil, "empty / nil")

        print("WindowKind")
        check(WindowKind.from(minutes: 300) == .session, "300 min → session")
        check(WindowKind.from(minutes: 10_080) == .weekly, "10080 min → weekly")
        check(WindowKind.from(minutes: 60) == .other(minutes: 60), "60 min → other")

        print("Formatting")
        check(StatusImage.dayHour(6 * 86_400 + 2 * 3_600 + 59 * 60) == "6d 2h", "6d 2h (minutes truncated)")
        check(StatusImage.dayHour(3 * 3_600) == "0d 3h", "0d 3h")
        check(StatusImage.dayHour(-50) == "0d 0h", "past → 0d 0h")

        print("UsageWindow.effective")
        let now = Date()
        let past = UsageWindow(kind: .weekly, usedPercent: 80, resetsAt: now.addingTimeInterval(-10), windowMinutes: 10_080)
        let e = past.effective(at: now)
        check(e.usedPercent == 0 && e.didReset && e.resetsAt == nil, "reset passed → 0% used, no invented next reset")
        let future = UsageWindow(kind: .weekly, usedPercent: 24.6, resetsAt: now.addingTimeInterval(3_600), windowMinutes: 10_080)
        check(future.effective(at: now).usedPercent == 24.6, "future reset unchanged")
        check(abs(future.remainingPercent - 75.4) < 0.001, "remaining = 100 - used")
        check(UsageWindow(kind: .weekly, usedPercent: 130, resetsAt: nil).remainingPercent == 0, "remaining clamps at 0")
        let half = UsageWindow(kind: .session, usedPercent: 0, resetsAt: now.addingTimeInterval(150 * 60), windowMinutes: 300)
        check(abs((half.elapsedFraction(at: now) ?? -1) - 0.5) < 0.001, "pace marker: half of 5h elapsed")

        print("Claude usage response")
        // Reset times relative to now, so the fixture never goes stale.
        let iso = ISO8601DateFormatter()
        let fiveHourReset = iso.string(from: now.addingTimeInterval(2 * 3600)).replacingOccurrences(of: "Z", with: ".614154+00:00")
        let weeklyReset = iso.string(from: now.addingTimeInterval(5 * 86_400)).replacingOccurrences(of: "Z", with: ".614171+00:00")
        let claudeJSON = """
        {"five_hour":{"utilization":11.0,"resets_at":"\(fiveHourReset)"},
         "seven_day":{"utilization":24.0,"resets_at":"\(weeklyReset)"},
         "seven_day_opus":null,"seven_day_oauth_apps":null,
         "extra_usage":{"is_enabled":false}}
        """
        if let snap = try? ClaudeProvider.parseUsage(Data(claudeJSON.utf8), plan: "max") {
            check(snap.windows.count == 2, "two windows (null model windows skipped)")
            check(snap.window { $0 == .session }?.usedPercent == 11, "5h utilization")
            check(snap.window { $0 == .weekly }?.remainingPercent == 76, "weekly remaining 76%")
            check(snap.window { $0 == .weekly }?.resetsAt != nil, "weekly reset parsed")
            check(snap.plan == "Max", "plan capitalized")
        } else { check(false, "parse Claude fixture") }
        check((try? ClaudeProvider.parseUsage(Data("{}".utf8), plan: nil)) == nil, "empty response → error")
        check((try? ClaudeProvider.parseUsage(Data("<html>".utf8), plan: nil)) == nil, "non-JSON → error")

        print("Codex usage response")
        let codexJSON = """
        {"plan_type":"pro","rate_limit":{"allowed":true,"limit_reached":false,
          "primary_window":{"used_percent":25,"limit_window_seconds":604800,"reset_after_seconds":500000,"reset_at":\(Int(now.timeIntervalSince1970) + 500_000)},
          "secondary_window":null}}
        """
        if let snap = CodexProvider.parseLive(Data(codexJSON.utf8)) {
            check(snap.windows.count == 1 && snap.windows[0].kind == .weekly, "primary 7-day classified as weekly")
            check(snap.windows[0].resetsAt == Date(timeIntervalSince1970: TimeInterval(Int(now.timeIntervalSince1970) + 500_000)), "reset_at epoch")
            check(snap.plan == "Pro", "plan")
        } else { check(false, "parse Codex fixture") }
        let codexBoth = """
        {"rate_limit":{"primary_window":{"used_percent":40,"limit_window_seconds":18000,"reset_after_seconds":3600},
                       "secondary_window":{"used_percent":10,"limit_window_seconds":604800,"reset_after_seconds":86400}}}
        """
        if let snap = CodexProvider.parseLive(Data(codexBoth.utf8)) {
            check(snap.windows.map(\.kind) == [.session, .weekly], "5h + weekly, sorted session first")
            check(snap.windows[0].resetsAt.map { abs($0.timeIntervalSinceNow - 3600) < 5 } ?? false, "reset_after_seconds fallback")
        } else { check(false, "parse Codex 5h+weekly fixture") }

        print("Codex session logs (real files on this Mac, read-only)")
        if let snap = CodexProvider().latestFromLogs() {
            check(!snap.windows.isEmpty, "found rate_limits in logs: \(snap.windows.map { "\($0.kind.title) \(Int($0.remainingPercent))% left" })")
        } else { print("  – no Codex logs in the last 8 days (skipped)") }

        print("Menu bar blocks")
        let settings = AppSettings()
        let store = UsageStore(settings: settings)
        let claudeSnap = try! ClaudeProvider.parseUsage(Data(claudeJSON.utf8), plan: nil)
        store.testInject(.claude, claudeSnap)
        store.testInject(.codex, CodexProvider.parseLive(Data(codexJSON.utf8))!)
        let saved = settings.barModes
        settings.barModes = [.claude: .weekly, .codex: .session]
        var b = StatusImage.blocks(store: store, settings: settings)
        check(b.count == 2, "both providers shown")
        check(b.first?.bottom == "76%", "Claude weekly 76%")
        check(b.last?.bottom == "75%", "Codex has no 5h window → falls back to weekly 75%")
        settings.barModes = [.claude: .both, .codex: .both]
        b = StatusImage.blocks(store: store, settings: settings)
        check(b.first?.top == "5h 89%" && b.first?.bottom == "7d 76%" && b.first?.equalLines == true, "Claude both → 5h/7d lines")
        check(b.last?.equalLines == false, "Codex both → single weekly (only one window)")
        settings.barModes = saved

        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
