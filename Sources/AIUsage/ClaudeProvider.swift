import Foundation
import Security

/// Reads Claude Code's OAuth login (macOS Keychain, or ~/.claude/.credentials.json)
/// and asks Anthropic's usage endpoint for the current 5-hour / 7-day utilization.
/// The token is never refreshed here — rotating it could log Claude Code out.
final class ClaudeProvider: @unchecked Sendable {
    private struct Credentials {
        let accessToken: String
        let expiresAt: Date?
        let subscriptionType: String?
        var isExpired: Bool { expiresAt.map { $0 < Date() } ?? false }
    }

    private static let keychainService = "Claude Code-credentials"
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private let lock = NSLock()
    private var cached: Credentials?
    /// Modification date of the keychain item the cached token came from (reading attributes never prompts).
    private var cachedVersion: Date?

    /// `interactive` is true only when the user pressed "Connect" / refresh. Background refreshes
    /// never show the Keychain prompt: if access would need approval they fail with `needsApproval`.
    func fetch(interactive: Bool = false) async throws -> ProviderSnapshot {
        var creds = try await credentialsOffThread(interactive: interactive, wantNewer: interactive)
        if creds.isExpired {
            creds = try await credentialsOffThread(interactive: interactive, wantNewer: true)   // Claude Code may have refreshed it
            if creds.isExpired {
                throw ProviderError(message: L.t(
                    "Claude Code의 로그인 정보가 오래됐어요. Claude Code를 한동안 실행하지 않으면 이렇게 돼요. 웹으로 로그인하면 이런 일 없이 계속 표시돼요.",
                    "Claude Code's login has gone stale (it hasn't run in a while). Log in on the web instead and it stays up to date."),
                    kind: .cliExpired)
            }
        }

        var data: Data, status: Int
        do {
            (data, status) = try await request(token: creds.accessToken)
            if status == 401 || status == 403 {
                let newer = try await credentialsOffThread(interactive: interactive, wantNewer: true)
                if newer.accessToken != creds.accessToken {
                    creds = newer
                    (data, status) = try await request(token: creds.accessToken)
                }
            }
        } catch {
            throw ProviderError.wrap(error)
        }
        switch status {
        case 200: break
        case 401, 403:
            throw ProviderError(message: L.t(
                "Claude Code 로그인이 더 이상 유효하지 않아요. 웹으로 로그인하거나 터미널에서 Claude Code에 다시 로그인해 주세요.",
                "Claude Code's login is no longer valid. Log in on the web, or log in to Claude Code again."),
                kind: .cliExpired)
        case 429: throw ProviderError.rateLimited
        default: throw ProviderError.server(status)
        }

        return try Self.parseUsage(data, plan: creds.subscriptionType)
    }

    static func parseUsage(_ data: Data, plan: String?) throws -> ProviderSnapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError(message: L.t("응답 형식을 해석할 수 없어요.", "Unexpected response format."))
        }

        var windows: [UsageWindow] = []
        func add(_ key: String, _ kind: WindowKind, minutes: Int) {
            guard let w = json[key] as? [String: Any], let util = Parse.double(w["utilization"]) else { return }
            windows.append(UsageWindow(kind: kind, usedPercent: util, resetsAt: Parse.date(w["resets_at"]), windowMinutes: minutes))
        }
        add("five_hour", .session, minutes: 300)
        add("seven_day", .weekly, minutes: 10_080)
        add("seven_day_opus", .weeklyModel("Opus"), minutes: 10_080)
        add("seven_day_sonnet", .weeklyModel("Sonnet"), minutes: 10_080)

        if windows.isEmpty {
            throw ProviderError(message: L.t(
                "이 계정에는 표시할 사용 한도가 없어요. 사용 한도는 Pro·Max 구독 플랜에서 제공돼요.",
                "This account has no usage limits to show. Limits come with Pro and Max plans."),
                kind: .noLimits)
        }
        return ProviderSnapshot(provider: .claude, windows: windows,
                                plan: plan?.capitalized,
                                source: .live, fetchedAt: Date())
    }

    private func request(token: String) async throws -> (Data, Int) {
        var req = URLRequest(url: Self.usageURL, timeoutInterval: 20)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("AIUsage", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// Claude Code has logged in on this Mac (checked without triggering any Keychain prompt).
    static var isSetUp: Bool {
        keychainItemVersion() != nil || FileManager.default.fileExists(atPath: credentialsFile.path)
    }

    private static var credentialsFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
    }

    private static func credentialsFileDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: credentialsFile.path))?[.modificationDate] as? Date
    }

    private func credentialsOffThread(interactive: Bool, wantNewer: Bool) async throws -> Credentials {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(with: Result { try self.credentials(interactive: interactive, wantNewer: wantNewer) })
            }
        }
    }

    // MARK: - Credentials

    /// Returns the cached token unless `wantNewer` is set and Claude Code has rewritten its keychain item.
    private func credentials(interactive: Bool, wantNewer: Bool) throws -> Credentials {
        lock.lock(); defer { lock.unlock() }

        let keychainVersion = Self.keychainItemVersion()
        let version = keychainVersion ?? Self.credentialsFileDate()
        if let c = cached, !wantNewer || version == nil || version == cachedVersion { return c }

        var raw: Data?
        if keychainVersion != nil {
            let (data, status) = Self.readSecret(interactive: interactive)
            if data == nil, status == errSecInteractionNotAllowed || status == errSecUserCanceled || status == errSecAuthFailed {
                if let c = cached, !c.isExpired { return c }
                throw ProviderError(message: status == errSecInteractionNotAllowed
                    ? L.t("Claude Code 로그인 정보를 읽으려면 macOS 허용이 한 번 필요해요. 버튼을 누르고 나오는 창에서 '항상 허용'을 선택해 주세요.",
                          "macOS needs your OK once to read Claude Code's login. Press the button and choose “Always Allow”.")
                    : L.t("macOS 허용 창에서 거부됐어요. 다시 시도하려면 버튼을 누르고 '항상 허용'을 선택해 주세요.",
                          "Access was denied. Press the button and choose “Always Allow” to try again."),
                    kind: .needsApproval)
            }
            raw = data
        }
        if raw == nil { raw = try? Data(contentsOf: Self.credentialsFile) }
        guard let data = raw else {
            throw ProviderError(message: L.t("이 Mac에서 Claude Code 로그인 정보를 찾지 못했어요. 웹으로 로그인해 주세요.",
                                             "No Claude Code login on this Mac. Log in on the web instead."), kind: .cliMissing)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw ProviderError(message: L.t("Claude Code 로그인 정보 형식을 읽을 수 없어요.", "Could not read Claude Code credentials."))
        }
        let c = Credentials(accessToken: token,
                            expiresAt: Parse.date(oauth["expiresAt"]),
                            subscriptionType: oauth["subscriptionType"] as? String)
        cached = c
        cachedVersion = version
        return c
    }

    /// SecKeychainSetUserInteractionAllowed is process-wide, so all keychain calls go through this lock.
    private static let keychainLock = NSLock()

    private static func withKeychain<T>(allowUI: Bool, _ body: () -> T) -> T {
        keychainLock.lock(); defer { keychainLock.unlock() }
        if !allowUI { SecKeychainSetUserInteractionAllowed(false) }
        defer { if !allowUI { SecKeychainSetUserInteractionAllowed(true) } }
        return body()
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecMatchLimit as String: kSecMatchLimitOne]
    }

    /// Item attributes only — never shows a prompt. nil when the item doesn't exist.
    private static func keychainItemVersion() -> Date? {
        var q = baseQuery
        q[kSecReturnAttributes as String] = true
        var out: CFTypeRef?
        let status = withKeychain(allowUI: false) { SecItemCopyMatching(q as CFDictionary, &out) }
        guard status == errSecSuccess, let attrs = out as? [String: Any] else { return nil }
        return (attrs[kSecAttrModificationDate as String] as? Date) ?? Date.distantPast
    }

    /// Reads Claude Code's secret, preferring routes that never show a dialog:
    ///  1. `/usr/bin/security` — Claude Code writes this item with that tool, so the item already
    ///     trusts it and it reads without any dialog. In the background it gets a short timeout so a
    ///     dialog it might raise is dismissed instead of interrupting the user.
    ///  2. our own Keychain access with dialogs switched off (works once the user chose "Always Allow")
    ///  3. only when the user pressed Connect: our own Keychain access with the dialog allowed.
    private static func readSecret(interactive: Bool) -> (Data?, OSStatus) {
        if let viaTool = readViaSecurityTool(timeout: interactive ? 60 : 3) { return (viaTool, errSecSuccess) }
        let (silent, status) = readKeychainSecret(allowPrompt: false)
        if let silent { return (silent, status) }
        return interactive ? readKeychainSecret(allowPrompt: true) : (nil, errSecInteractionNotAllowed)
    }

    private static func readViaSecurityTool(timeout: TimeInterval) -> Data? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }

        var output = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            output = out.fileHandleForReading.readDataToEndOfFile()   // returns at EOF, i.e. when the tool exits
            proc.waitUntilExit()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }
        var data = output
        while let last = data.last, last == 0x0A || last == 0x0D { data.removeLast() }
        // `security -w` prints binary-looking values as hex.
        if data.first != UInt8(ascii: "{"), let text = String(data: data, encoding: .utf8), let decoded = Data(hex: text) {
            data = decoded
        }
        return data.isEmpty ? nil : data
    }

    /// Reads the secret itself. With `allowPrompt == false` macOS fails with
    /// errSecInteractionNotAllowed instead of showing the "allow access" dialog.
    private static func readKeychainSecret(allowPrompt: Bool) -> (Data?, OSStatus) {
        var q = baseQuery
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        // kSecUseAuthenticationUIFail alone doesn't stop the legacy "allow access" dialog;
        // turning off keychain user interaction for the call does.
        let status = withKeychain(allowUI: allowPrompt) { SecItemCopyMatching(q as CFDictionary, &out) }
        return (status == errSecSuccess ? out as? Data : nil, status)
    }
}

private extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0, !hex.isEmpty else { return nil }
        var bytes = [UInt8](); bytes.reserveCapacity(hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            bytes.append(b); i = j
        }
        self.init(bytes)
    }
}
