import AppKit

enum Provider: String, CaseIterable, Identifiable {
    case claude, codex

    var id: String { rawValue }
    var displayName: String { self == .claude ? "Claude" : "Codex" }
    var barLabel: String { self == .claude ? "CLAUDE" : "CODEX" }

    var isSetUp: Bool { self == .claude ? ClaudeProvider.isSetUp : CodexProvider.isSetUp }

    var loginCommand: String { self == .claude ? "claude" : "codex login" }
    var cliName: String { self == .claude ? "Claude Code" : "Codex CLI" }
    var website: String { self == .claude ? "claude.ai" : "chatgpt.com" }
    var accountName: String { self == .claude ? L.t("Claude 계정", "Claude account") : L.t("ChatGPT 계정", "ChatGPT account") }

    /// Opens Terminal running the CLI's login command (via a temporary .command file).
    func openLoginInTerminal() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AIUsage", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("login-\(rawValue).command")
        let note = self == .claude
            ? L.t("Claude Code가 열리면 로그인 정보가 갱신됩니다. 로그인하라는 안내가 나오면 따라 주세요.\n갱신이 끝나면 /exit 를 입력하고 이 창을 닫아도 됩니다. AI Usage가 자동으로 알아차려요.",
                  "When Claude Code opens, its login is refreshed. Follow any login prompt.\nThen type /exit and close this window — AI Usage picks it up automatically.")
            : L.t("브라우저가 열리면 ChatGPT 계정으로 로그인해 주세요. 끝나면 이 창을 닫아도 됩니다.",
                  "Log in with your ChatGPT account in the browser that opens, then close this window.")
        let script = "#!/bin/zsh -l\nclear\necho 'AI Usage — \(cliName)'\necho\necho '\(note.replacingOccurrences(of: "'", with: ""))'\necho\n\(loginCommand)\n"
        try? script.write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        NSWorkspace.shared.open(file)
    }

    var setupHint: String {
        self == .claude
            ? L.t("Claude Code에 로그인하지 않았어요. 터미널에서 claude를 실행해 로그인하면 자동으로 표시됩니다.",
                  "Claude Code isn't logged in. Run `claude` in a terminal and log in; it will appear automatically.")
            : L.t("Codex에 로그인하지 않았어요. 터미널에서 codex login을 실행하면 자동으로 표시됩니다.",
                  "Codex isn't logged in. Run `codex login` in a terminal; it will appear automatically.")
    }
}

enum WindowKind: Equatable {
    case session                 // 5-hour rolling session
    case weekly                  // 7-day window
    case weeklyModel(String)     // 7-day window scoped to one model (e.g. Opus)
    case other(minutes: Int)

    static func from(minutes: Int?) -> WindowKind {
        guard let m = minutes else { return .other(minutes: 0) }
        switch m {
        case 240...360: return .session
        case 9_000...11_000: return .weekly
        default: return .other(minutes: m)
        }
    }

    var sortOrder: Int {
        switch self {
        case .session: return 0
        case .weekly: return 1
        case .weeklyModel: return 2
        case .other: return 3
        }
    }

    var title: String {
        switch self {
        case .session: return L.t("5시간 세션", "5-hour session")
        case .weekly: return L.t("주간 (7일)", "Weekly (7 days)")
        case .weeklyModel(let name): return L.t("주간 · \(name)", "Weekly · \(name)")
        case .other(let m):
            if m >= 60 { return L.t("\(m / 60)시간 한도", "\(m / 60)-hour limit") }
            return L.t("사용 한도", "Usage limit")
        }
    }
}

struct UsageWindow: Identifiable {
    var kind: WindowKind
    var usedPercent: Double
    var resetsAt: Date?
    var windowMinutes: Int?
    var didReset = false

    var id: String { kind.title }
    var remainingPercent: Double { usedPercent.isFinite ? max(0, min(100, 100 - usedPercent)) : 0 }

    /// The number shown to the user ("72%"), or "?%" when the value isn't a usable number.
    func percentText(showRemaining: Bool) -> String {
        guard usedPercent.isFinite else { return "?%" }
        let value = showRemaining ? remainingPercent : max(0, min(999, usedPercent))
        return "\(Int(value.rounded()))%"
    }

    /// Bar fill (0...1) for the shown value.
    func barFraction(showRemaining: Bool) -> Double {
        guard usedPercent.isFinite else { return 0 }
        return (showRemaining ? remainingPercent : max(0, min(100, usedPercent))) / 100
    }

    /// A window whose reset time has already passed is shown as fully available
    /// until the next refresh brings real numbers.
    func effective(at now: Date) -> UsageWindow {
        guard let r = resetsAt, r <= now else { return self }
        var w = self
        w.usedPercent = 0
        w.didReset = true
        w.resetsAt = nil   // the next window starts with the next use; the next refresh brings the real time
        return w
    }

    /// Fraction of the window that has elapsed (0...1), used for the "even pace" marker.
    func elapsedFraction(at now: Date) -> Double? {
        guard let r = resetsAt, let m = windowMinutes, m > 0 else { return nil }
        let total = TimeInterval(m) * 60
        let f = 1 - r.timeIntervalSince(now) / total
        return f.isFinite ? max(0, min(1, f)) : nil
    }
}

enum DataSource {
    case live        // CLI login → official usage API
    case web         // in-app web login
    case log(Date)   // Codex session log fallback
}

struct ProviderSnapshot {
    var provider: Provider
    var windows: [UsageWindow]
    var plan: String?
    var source: DataSource
    var fetchedAt: Date

    func window(_ match: (WindowKind) -> Bool) -> UsageWindow? {
        windows.first { match($0.kind) }
    }
}

/// How a provider's usage is read.
enum Connection: String {
    case none
    case web   // logged in inside the app (claude.ai / chatgpt.com)
    case cli   // reuse the Claude Code / Codex CLI login on this Mac
}

struct ProviderError: LocalizedError {
    enum Kind {
        case generic
        case needsApproval   // CLI: Keychain access needs the user's OK
        case cliExpired      // CLI: token is stale because the CLI hasn't run lately
        case cliMissing      // CLI: not logged in on this Mac
        case needsLogin      // web: not logged in / session expired
        case network         // offline, unreachable or timed out
        case server          // 5xx and other temporary server errors
        case rateLimited
        case noLimits        // account has no plan limits to show (e.g. free plan)
    }

    let message: String
    var kind: Kind = .generic
    /// For `.rateLimited`: the earliest time the server allows another request.
    var retryAt: Date?
    var errorDescription: String? { message }

    var needsApproval: Bool { kind == .needsApproval }

    /// Maps URLSession / unknown errors to friendly ones.
    static func wrap(_ error: Error) -> ProviderError {
        if let e = error as? ProviderError { return e }
        if (error as? URLError) != nil || (error as NSError).domain == NSURLErrorDomain {
            return ProviderError(message: L.t(
                "서버에 연결하지 못했어요. 인터넷 연결을 확인해 주세요. 연결되면 자동으로 다시 불러와요.",
                "Couldn't reach the server. Check your internet connection — it will retry automatically."), kind: .network)
        }
        return ProviderError(message: error.localizedDescription)
    }

    static func rateLimited(until: Date) -> ProviderError {
        ProviderError(message: L.t(
            "요청이 많아 잠시 쉬고 있어요. \(L.time(until)) 이후 자동으로 다시 불러와요.",
            "Paused after too many requests. It will try again after \(L.time(until))."),
            kind: .rateLimited, retryAt: until)
    }

    static func server(_ status: Int) -> ProviderError {
        ProviderError(message: L.t(
            "서버가 일시적으로 응답하지 않아요 (코드 \(status)). 잠시 후 자동으로 다시 시도해요.",
            "The server isn't responding right now (code \(status)). It will retry shortly."), kind: .server)
    }

    static let timedOut = ProviderError(message: L.t(
        "응답이 너무 늦어 이번 조회를 멈췄어요. 잠시 후 자동으로 다시 시도해요.",
        "The server took too long, so this check was stopped. It will retry shortly."), kind: .network)
}

// MARK: - Parsing helpers

enum Parse {
    /// A finite number. JSON booleans are not numbers here (`true` must never read as 1%).
    static func double(_ v: Any?) -> Double? {
        let d: Double?
        switch v {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            d = n.doubleValue
        case let s as String:
            let t = s.trimmingCharacters(in: .whitespaces)
            d = t.isEmpty ? nil : Double(t)
        default:
            d = nil
        }
        guard let d, d.isFinite else { return nil }
        return d
    }

    /// An integer that fits in Int. Integer strings are read exactly (no Double round trip);
    /// fractional values are truncated toward zero; anything non-finite or out of range is nil.
    static func int(_ v: Any?) -> Int? {
        if let s = v as? String {
            let t = s.trimmingCharacters(in: .whitespaces)
            if let i = Int(t) { return i }
            return Double(t).flatMap(int(fromDouble:))
        }
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), !CFNumberIsFloatType(n) {
            return n.intValue
        }
        return double(v).flatMap(int(fromDouble:))
    }

    private static func int(fromDouble d: Double) -> Int? {
        guard d.isFinite, d > -9.2e18, d < 9.2e18 else { return nil }
        return Int(d.rounded(.towardZero))
    }

    /// Usage in percent of the limit. Over 100 is allowed (a limit can be exceeded, e.g. extra usage);
    /// negative or absurd values mean a bad response and are rejected.
    static func percent(_ v: Any?) -> Double? {
        guard let d = double(v), d >= 0, d <= 1000 else { return nil }
        return d
    }

    /// Length of a limit window in minutes: 1 minute to 1 year.
    static func windowMinutes(_ v: Int?) -> Int? {
        guard let v, v >= 1, v <= 366 * 1440 else { return nil }
        return v
    }

    static let earliestDate = Date(timeIntervalSince1970: 946_684_800)   // 2000-01-01
    static let latestDate = Date(timeIntervalSince1970: 4_102_444_800)   // 2100-01-01

    /// A date between 2000 and 2100, or nil.
    static func validDate(_ d: Date?) -> Date? {
        guard let d, d >= earliestDate, d <= latestDate else { return nil }
        return d
    }

    /// Accepts epoch seconds / milliseconds or ISO-8601 strings (with any fractional precision).
    static func date(_ v: Any?) -> Date? {
        if !(v is String), let d = double(v) {
            return validDate(Date(timeIntervalSince1970: d > 10_000_000_000 ? d / 1000 : d))
        }
        guard var s = v as? String, !s.isEmpty else { return nil }
        if let dot = s.firstIndex(of: ".") {
            var end = s.index(after: dot)
            while end < s.endIndex, s[end].isNumber { end = s.index(after: end) }
            s.removeSubrange(dot..<end)
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return validDate(f.date(from: s))
    }

    /// `seconds` from `now`, if the result is a valid date.
    static func date(after seconds: Double?, from now: Date) -> Date? {
        guard let seconds, seconds.isFinite, seconds >= 0, seconds < 400 * 86_400 else { return nil }
        return validDate(now.addingTimeInterval(seconds))
    }
}

/// How long to wait before asking a server again.
enum RetryPolicy {
    /// Floor and ceiling for a server-requested wait, and the wait when it doesn't say.
    static let minimumWait: TimeInterval = 30
    static let defaultWait: TimeInterval = 300
    static let maximumWait: TimeInterval = 3600
    /// Offline / timeout / 5xx: try again after this (the button can still retry sooner).
    static let transientRetry: TimeInterval = 60

    /// When a 429 response allows the next request. `Retry-After` may be seconds or an HTTP date;
    /// missing, malformed or negative values use the default; anything else is kept within bounds.
    static func retryAt(header: String?, now: Date) -> Date {
        guard let raw = header?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return now.addingTimeInterval(defaultWait) }
        if let seconds = Int(raw) {
            return now.addingTimeInterval(seconds < 0 ? defaultWait : clamp(TimeInterval(seconds)))
        }
        if let date = httpDate(raw) { return now.addingTimeInterval(clamp(date.timeIntervalSince(now))) }
        return now.addingTimeInterval(defaultWait)
    }

    private static func clamp(_ wait: TimeInterval) -> TimeInterval { max(minimumWait, min(maximumWait, wait)) }

    private static let httpDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    static func httpDate(_ s: String) -> Date? { httpDateFormatter.date(from: s) }
}
