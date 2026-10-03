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
            if var snap = try await fetchLive() { snap.accountKey = accountKey(); return snap }
        } catch let e as ProviderError where e.kind == .rateLimited {
            throw e   // keep the server's wait; older log numbers mustn't hide that live checks are paused
        } catch {
            liveError = error
        }
        if var snap = latestFromLogs() { snap.accountKey = accountKey(); return snap }

        if let e = liveError { throw ProviderError.wrap(e) }
        let hasAuth = FileManager.default.fileExists(atPath: codexHome.appendingPathComponent("auth.json").path)
        throw hasAuth
            ? ProviderError(message: L.t("Codex CLI가 ChatGPT 계정이 아닌 API 키로 로그인돼 있어서 사용 한도 정보가 없어요. 웹으로 로그인해 주세요.",
                                         "Codex CLI is logged in with an API key, which has no plan limits. Log in on the web instead."), kind: .cliMissing)
            : ProviderError(message: L.t("이 Mac에서 Codex CLI 로그인 정보를 찾지 못했어요. 웹으로 로그인해 주세요.",
                                         "No Codex CLI login on this Mac. Log in on the web instead."), kind: .cliMissing)
    }

    private func accountKey() -> String? {
        (try? Data(contentsOf: codexHome.appendingPathComponent("auth.json")))
            .flatMap(AccountKey.codexAccount).flatMap { AccountKey.make(.codex, id: $0) }
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
            if status == 429 {
                let header = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
                throw ProviderError.rateLimited(until: RetryPolicy.retryAt(header: header, now: Date()))
            }
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
            guard let w = limits[key] as? [String: Any], let used = Parse.percent(w["used_percent"]) else { return nil }
            let minutes = Parse.windowMinutes(Parse.int(w["limit_window_seconds"]).map { $0 / 60 })
            let reset = Parse.date(w["reset_at"]) ?? Parse.date(after: Parse.double(w["reset_after_seconds"]), from: Date())
            return UsageWindow(kind: .from(minutes: minutes), usedPercent: used, resetsAt: reset, windowMinutes: minutes)
        }
        guard !windows.isEmpty else { return nil }
        return ProviderSnapshot(provider: .codex, windows: windows.sorted { $0.kind.sortOrder < $1.kind.sortOrder },
                                plan: (json["plan_type"] as? String)?.capitalized,
                                source: .live, fetchedAt: Date())
    }

    // MARK: - Session logs

    /// Limits that keep the log fallback cheap.
    static let logRecentDays = 8          // only files touched in this many days
    static let logMaxFiles = 40           // files actually read
    static let logTailBytes = 1_000_000   // bytes read from the end of each file
    static let logMaxEntriesVisited = 20_000

    /// The newest valid `rate_limits` event in recent Codex session logs.
    /// File modification times only decide the reading order; the result is chosen by event time.
    /// Only the usage numbers are extracted — conversation text in these files is never kept.
    func latestFromLogs(now: Date = Date()) -> ProviderSnapshot? {
        let files = recentLogFiles(now: now)
        var best: (Date, ProviderSnapshot)?
        for (file, mtime) in files.prefix(Self.logMaxFiles) {
            // Files are sorted newest-first; a file can't hold an event newer than its last write.
            if let b = best, mtime < b.0 { break }
            guard let (data, cut) = Self.readTail(of: file, bytes: Self.logTailBytes) else { continue }
            for event in Self.events(inTail: data, startsMidFile: cut, now: now) where best.map({ event.0 > $0.0 }) ?? true {
                best = event
            }
        }
        return best?.1
    }

    /// rollout-*.jsonl files modified recently, newest first: the dated folders of the last days,
    /// plus older folders (a resumed conversation keeps writing to its original day's folder).
    private func recentLogFiles(now: Date) -> [(URL, Date)] {
        let fm = FileManager.default
        let base = codexHome.appendingPathComponent("sessions")
        let cutoff = now.addingTimeInterval(-Double(Self.logRecentDays) * 86_400)
        var found: [URL: Date] = [:]
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walker = fm.enumerator(at: base, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        var visited = 0
        for case let url as URL in walker {
            visited += 1
            if visited > Self.logMaxEntriesVisited { break }
            guard url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl",
                  let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  let m = v.contentModificationDate, m >= cutoff else { continue }
            found[url] = m
        }
        return found.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    /// The last `bytes` of a file, and whether that cut off the start of the file.
    static func readTail(of file: URL, bytes: Int) -> (Data, Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        return (data, start > 0)
    }

    /// Usage events in a chunk of JSONL. Lines are split on bytes, so a cut in the middle of a
    /// multi-byte character only spoils the first (partial) line, which is dropped. CRLF, a last line
    /// without newline, corrupt lines and a half-written last line are all tolerated.
    /// Events with a missing or invalid timestamp are skipped rather than treated as "now".
    static func events(inTail data: Data, startsMidFile: Bool, now: Date) -> [(Date, ProviderSnapshot)] {
        var bytes = data[...]
        if startsMidFile {
            guard let nl = bytes.firstIndex(of: 0x0A) else { return [] }
            bytes = bytes[bytes.index(after: nl)...]
        }
        let marker = Array("\"rate_limits\"".utf8)
        let latestAllowed = now.addingTimeInterval(3600)   // tolerate small clock differences only
        var out: [(Date, ProviderSnapshot)] = []
        for rawLine in bytes.split(separator: 0x0A, omittingEmptySubsequences: true) {
            var line = rawLine
            if line.last == 0x0D { line = line.dropLast() }
            guard line.firstRange(of: marker) != nil,
                  let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let eventTime = Parse.date(obj["timestamp"]), eventTime <= latestAllowed else { continue }
            let payload = obj["payload"] as? [String: Any]
            guard let limits = (payload?["rate_limits"] ?? obj["rate_limits"]) as? [String: Any] else { continue }
            if let id = limits["limit_id"] as? String, id != "codex" { continue }

            let windows = ["primary", "secondary"].compactMap { key -> UsageWindow? in
                guard let w = limits[key] as? [String: Any], let used = Parse.percent(w["used_percent"]) else { return nil }
                let minutes = Parse.windowMinutes(Parse.int(w["window_minutes"]))
                let reset = Parse.date(w["resets_at"]) ?? Parse.date(after: Parse.double(w["resets_in_seconds"]), from: eventTime)
                return UsageWindow(kind: .from(minutes: minutes), usedPercent: used, resetsAt: reset, windowMinutes: minutes)
            }
            guard !windows.isEmpty else { continue }
            out.append((eventTime, ProviderSnapshot(provider: .codex, windows: windows.sorted { $0.kind.sortOrder < $1.kind.sortOrder },
                                                    plan: (limits["plan_type"] as? String)?.capitalized,
                                                    source: .log(eventTime), fetchedAt: now)))
        }
        return out
    }
}
