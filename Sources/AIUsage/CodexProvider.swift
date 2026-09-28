import Foundation

/// Codex usage comes from two places:
///  1. live: ChatGPT's usage endpoint, using the login Codex CLI keeps in ~/.codex/auth.json
///  2. fallback: the `rate_limits` snapshot Codex writes into its session logs after every turn
final class CodexProvider: @unchecked Sendable {
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    /// Codex CLI has logged in or been used on this Mac.
    static var isSetUp: Bool {
        let home = CodexProvider().codexHome
        return FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path) ||
            FileManager.default.fileExists(atPath: home.appendingPathComponent("sessions").path)
    }

    private var codexHome: URL {
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    func fetch() async throws -> ProviderSnapshot {
        var liveError: Error?
        do {
            if let snap = try await fetchLive() { return snap }
        } catch {
            liveError = error
        }
        if let snap = latestFromLogs() { return snap }

        if let e = liveError { throw ProviderError.wrap(e) }
        let hasAuth = FileManager.default.fileExists(atPath: codexHome.appendingPathComponent("auth.json").path)
        throw hasAuth
            ? ProviderError(message: L.t("Codex CLI가 ChatGPT 계정이 아닌 API 키로 로그인돼 있어서 사용 한도 정보가 없어요. 웹으로 로그인해 주세요.",
                                         "Codex CLI is logged in with an API key, which has no plan limits. Log in on the web instead."), kind: .cliMissing)
            : ProviderError(message: L.t("이 Mac에서 Codex CLI 로그인 정보를 찾지 못했어요. 웹으로 로그인해 주세요.",
                                         "No Codex CLI login on this Mac. Log in on the web instead."), kind: .cliMissing)
    }

    // MARK: - Live

    private func fetchLive() async throws -> ProviderSnapshot? {
        let authURL = codexHome.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty else {
            return nil   // API-key login or not logged in: no subscription limits to show live
        }

        var req = URLRequest(url: Self.usageURL, timeoutInterval: 20)
        req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        if let account = tokens["account_id"] as? String {
            req.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("codex_cli_rs", forHTTPHeaderField: "User-Agent")

        let (body, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if status == 429 { throw ProviderError.rateLimited }
            throw status == 401 || status == 403
                ? ProviderError(message: L.t("Codex CLI의 로그인 정보가 오래됐어요. Codex를 한동안 실행하지 않으면 이렇게 돼요. 웹으로 로그인하면 계속 표시돼요.",
                                             "Codex CLI's login has gone stale. Log in on the web instead and it stays up to date."), kind: .cliExpired)
                : ProviderError.server(status)
        }
        return Self.parseLive(body)
    }

    static func parseLive(_ body: Data) -> ProviderSnapshot? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let limits = json["rate_limit"] as? [String: Any] else { return nil }

        let windows = ["primary_window", "secondary_window"].compactMap { key -> UsageWindow? in
            guard let w = limits[key] as? [String: Any], let used = Parse.double(w["used_percent"]) else { return nil }
            let minutes = Parse.int(w["limit_window_seconds"]).map { $0 / 60 }
            var reset = Parse.date(w["reset_at"])
            if reset == nil, let after = Parse.double(w["reset_after_seconds"]) { reset = Date().addingTimeInterval(after) }
            return UsageWindow(kind: .from(minutes: minutes), usedPercent: used, resetsAt: reset, windowMinutes: minutes)
        }
        guard !windows.isEmpty else { return nil }
        return ProviderSnapshot(provider: .codex, windows: windows.sorted { $0.kind.sortOrder < $1.kind.sortOrder },
                                plan: (json["plan_type"] as? String)?.capitalized,
                                source: .live, fetchedAt: Date())
    }

    // MARK: - Session logs

    /// Scans the last 8 days of ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl, newest first,
    /// and returns the most recent `rate_limits` event.
    func latestFromLogs() -> ProviderSnapshot? {
        let fm = FileManager.default
        let base = codexHome.appendingPathComponent("sessions")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        var files: [(URL, Date)] = []
        for offset in 0..<8 {
            guard let day = cal.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: day)
            let dir = base.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for f in items where f.lastPathComponent.hasPrefix("rollout-") && f.pathExtension == "jsonl" {
                let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                files.append((f, m))
            }
        }
        files.sort { $0.1 > $1.1 }

        for (file, _) in files.prefix(30) {
            if let snap = parseLatest(in: file) { return snap }
        }
        return nil
    }

    private func parseLatest(in file: URL) -> ProviderSnapshot? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let chunk: UInt64 = 1_000_000
        try? handle.seek(toOffset: size > chunk ? size - chunk : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let payload = obj["payload"] as? [String: Any]
            guard let limits = (payload?["rate_limits"] ?? obj["rate_limits"]) as? [String: Any] else { continue }
            if let id = limits["limit_id"] as? String, id != "codex" { continue }
            let eventTime = Parse.date(obj["timestamp"]) ?? Date()

            let windows = ["primary", "secondary"].compactMap { key -> UsageWindow? in
                guard let w = limits[key] as? [String: Any], let used = Parse.double(w["used_percent"]) else { return nil }
                let minutes = Parse.int(w["window_minutes"])
                var reset = Parse.date(w["resets_at"])
                if reset == nil, let secs = Parse.double(w["resets_in_seconds"]) { reset = eventTime.addingTimeInterval(secs) }
                return UsageWindow(kind: .from(minutes: minutes), usedPercent: used, resetsAt: reset, windowMinutes: minutes)
            }
            guard !windows.isEmpty else { continue }
            return ProviderSnapshot(provider: .codex, windows: windows.sorted { $0.kind.sortOrder < $1.kind.sortOrder },
                                    plan: (limits["plan_type"] as? String)?.capitalized,
                                    source: .log(eventTime), fetchedAt: Date())
        }
        return nil
    }
}
