// Store concurrency and retry tests with a fake backend, fake clock and fake scheduler.
// No network, Keychain, login windows or real waiting.
import AppKit

@MainActor
final class FakeBackend: UsageBackend {
    final class Call {
        let p: Provider, connection: Connection, interactive: Bool
        var cont: CheckedContinuation<ProviderSnapshot, Error>?
        init(_ p: Provider, _ c: Connection, _ i: Bool) { self.p = p; connection = c; interactive = i }
    }
    var calls: [Call] = []
    var logins: [(Provider, (Bool) -> Void)] = []
    var dismissed: [Provider] = []
    var forgotten: [(Provider, Connection)] = []
    var sharedCleared: [Bool] = []
    var holdForget = false
    private var forgetWaiters: [CheckedContinuation<Void, Never>] = []

    var pending: [Call] { calls.filter { $0.cont != nil } }

    func fetch(_ p: Provider, via connection: Connection, interactive: Bool) async throws -> ProviderSnapshot {
        let call = Call(p, connection, interactive)
        calls.append(call)
        return try await withCheckedThrowingContinuation { call.cont = $0 }
    }
    func presentLogin(_ p: Provider, done: @escaping @MainActor (Bool) -> Void) { logins.append((p, done)) }
    func dismissLogin(_ p: Provider) { dismissed.append(p) }
    func forgetAppData(_ p: Provider, connection: Connection, clearSharedSignIn: Bool) async {
        forgotten.append((p, connection))
        sharedCleared.append(clearSharedSignIn)
        if holdForget { await withCheckedContinuation { forgetWaiters.append($0) } }
    }
    func releaseForget() { forgetWaiters.forEach { $0.resume() }; forgetWaiters = [] }
    func openTerminalLogin(_ p: Provider) {}
    func isCLISetUp(_ p: Provider) -> Bool { true }

    func succeed(_ call: Call, used: Double, at: Date) {
        let w = UsageWindow(kind: .weekly, usedPercent: used, resetsAt: at.addingTimeInterval(86_400), windowMinutes: 10_080)
        call.cont?.resume(returning: ProviderSnapshot(provider: call.p, windows: [w], plan: nil, source: .live, fetchedAt: at))
        call.cont = nil
    }
    func fail(_ call: Call, _ e: ProviderError) { call.cont?.resume(throwing: e); call.cont = nil }
    /// Resolve everything still open so no continuation leaks at the end of a test.
    func drain() { for c in calls where c.cont != nil { fail(c, ProviderError(message: "drained")) } }
}

@MainActor
final class FakeTime {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    struct Job { let due: Date; let action: @MainActor () -> Void; var cancelled = false }
    var jobs: [Job] = []
    lazy var scheduler: Scheduler = { [unowned self] delay, action in
        let i = self.jobs.count
        self.jobs.append(Job(due: self.now.addingTimeInterval(delay), action: action))
        return { [unowned self] in self.jobs[i].cancelled = true }
    }
    /// Moves the clock and runs every job that has become due, exactly once.
    func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        for i in jobs.indices where !jobs[i].cancelled && jobs[i].due <= now {
            jobs[i].cancelled = true
            jobs[i].action()
        }
    }
}

enum StoreTests {
    /// Lets queued main-actor work run. Deterministic: only yields, never sleeps.
    @MainActor static func settle() async { for _ in 0..<200 { await Task.yield() } }

    /// Yields until `condition` holds (or a generous yield budget runs out).
    @MainActor static func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<5_000 { if condition() { return true }; await Task.yield() }
        return condition()
    }

    @MainActor static func make(_ connections: [Provider: Connection] = [.claude: .cli])
        -> (UsageStore, FakeBackend, FakeTime, AppSettings) {
        let s = AppSettings.forTesting()
        for (p, c) in connections { s.connections[p] = c }
        let b = FakeBackend(), t = FakeTime()
        let st = UsageStore(settings: s, backend: b, clock: { t.now }, schedule: t.scheduler)
        return (st, b, t, s)
    }

    @MainActor static func used(_ st: UsageStore, _ p: Provider = .claude) -> Double? {
        st.entries[p]?.snapshot?.windows.first?.usedPercent
    }

    @MainActor static func run() async {
        print("Store: duplicate requests")
        do {
            let (st, b, t, _) = make()
            st.refresh(.claude)                    // normal
            st.refresh(.claude, manual: true)      // manual button
            st.refreshAll()                        // timer
            st.refreshIfStale()                    // menu opened
            st.refreshAll()                        // wake from sleep
            await settle()
            check(b.calls.count == 1, "five triggers at once → one request (got \(b.calls.count))")
            if b.calls.count >= 2 {   // the bug: two in flight; answer them out of order
                b.succeed(b.calls[1], used: 80, at: t.now); await settle()
                b.succeed(b.calls[0], used: 10, at: t.now); await settle()
            } else {
                b.succeed(b.calls[0], used: 80, at: t.now); await settle()
            }
            check(used(st) == 80, "final value is the newest answer, not a late older one (got \(used(st).map { "\($0)" } ?? "nil"))")
            b.drain()
        }

        print("Store: disconnect and reconnect")
        do {
            let (st, b, t, s) = make()
            st.refresh(.claude); await settle()
            st.disconnect(.claude); await settle()
            st.useCLI(.claude); await settle()       // same connection kind again
            check(s.connection(.claude) == .cli, "reconnected")
            let newest = b.calls.last!
            b.succeed(newest, used: 80, at: t.now); await settle()
            b.succeed(b.calls[0], used: 10, at: t.now); await settle()   // answer from before the disconnect
            check(used(st) == 80, "an answer from before the disconnect is ignored (got \(used(st).map { "\($0)" } ?? "nil"))")
            check(b.forgotten.contains { $0.0 == .claude && $0.1 == .cli }, "disconnect drops the app's cached Claude token")
            b.drain()
        }
        do {
            let (st, b, t, _) = make()
            st.refresh(.claude); await settle()
            st.disconnect(.claude); st.useCLI(.claude); await settle()
            b.succeed(b.calls.last!, used: 80, at: t.now); await settle()
            b.fail(b.calls[0], ProviderError(message: "old", kind: .network)); await settle()
            check(st.entries[.claude]?.error == nil && used(st) == 80, "a late failure from before the disconnect is ignored")
            b.drain()
        }
        do {
            let (st, b, _, s) = make()
            st.refresh(.claude); await settle()
            st.disconnect(.claude); await settle()
            check(s.connection(.claude) == .none && st.entries[.claude] == nil, "disconnect clears the card")
            let before = b.calls.count
            st.refreshAll(); st.refresh(.claude, manual: true); await settle()
            check(b.calls.count == before, "no request after disconnect")
            b.drain()
        }

        print("Store: web login window")
        do {
            let (st, b, _, s) = make([:])
            st.logInOnWeb(.claude); await settle()
            b.logins.last?.1(false); await settle()
            check(s.connection(.claude) == .none && st.loggingIn.isEmpty && b.calls.isEmpty, "closing the login window changes nothing")
        }
        do {
            let (st, b, _, s) = make()
            st.logInOnWeb(.claude); await settle()
            st.disconnect(.claude); await settle()
            let before = b.calls.count
            b.logins.last?.1(true); await settle()    // the old window reports success late
            check(s.connection(.claude) == .none, "a login that finishes after disconnect doesn't reconnect (got \(s.connection(.claude)))")
            check(b.calls.count == before, "…and starts no request")
            check(b.dismissed.contains(.claude), "disconnect closes the open login window")
            b.drain()
        }
        do {
            let (st, b, _, _) = make([.claude: .web])
            b.holdForget = true
            st.disconnect(.claude); await settle()
            st.logInOnWeb(.claude); await settle()
            check(b.logins.isEmpty, "a new login waits until the old login data is erased")
            b.releaseForget()
            check(await eventually { b.logins.count == 1 }, "…then opens")
            b.drain()
        }

        print("Store: what a disconnect erases")
        do {
            let (st, b, _, _) = make([.claude: .web, .codex: .web])
            st.disconnect(.claude); await settle()
            check(b.sharedCleared.last == false, "Codex still uses web login → Google/Apple sign-in kept")
            st.disconnect(.codex); await settle()
            check(b.sharedCleared.last == true, "no web login left → shared sign-in data erased too")
            let (st2, b2, _, _) = make([.claude: .cli, .codex: .web])
            st2.disconnect(.claude); await settle()
            check(b2.sharedCleared.last == false && b2.forgotten.last?.1 == .cli, "CLI disconnect erases only the app's token cache")
            b.drain(); b2.drain()
        }

        print("Store: request timeout")
        do {
            let (st, b, t, _) = make()
            st.refresh(.claude); await settle()
            t.advance(UsageStore.requestTimeout + 1); await settle()
            check(st.entries[.claude]?.loading == false && st.entries[.claude]?.error?.kind == .network, "a request that never answers times out")
            st.refresh(.claude, manual: true); await settle()
            check(b.calls.count == 2, "a new request can start after the timeout")
            b.succeed(b.calls[1], used: 70, at: t.now); await settle()
            b.succeed(b.calls[0], used: 10, at: t.now); await settle()
            check(used(st) == 70, "the timed-out request's late answer is ignored")
            b.drain()
        }

        print("Store: server retry wait (429)")
        do {
            let (st, b, t, _) = make()
            st.refresh(.claude); await settle()
            let until = t.now.addingTimeInterval(300)
            b.fail(b.calls[0], ProviderError(message: "429", kind: .rateLimited, retryAt: until)); await settle()
            st.refreshIfStale(); st.refreshAll(); st.refresh(.claude, manual: true); st.useCLI(.claude); await settle()
            check(b.calls.count == 1, "menu, timer, button and reconnect don't bypass the wait (got \(b.calls.count) requests)")
            t.advance(299); await settle()
            check(b.calls.count == 1, "nothing one second before the allowed time")
            t.advance(1); await settle()
            check(b.calls.count == 2, "exactly one retry at the allowed time (got \(b.calls.count))")
            check(st.entries[.claude]?.error?.retryAt == until, "the card keeps the wait-until time while waiting")
            b.drain()
        }
        do {
            let (st, b, _, _) = make()
            st.refresh(.claude); await settle()
            b.fail(b.calls[0], ProviderError(message: "offline", kind: .network)); await settle()
            st.refresh(.claude, manual: true); await settle()
            check(b.calls.count == 2, "after a network error the button can retry right away")
            b.drain()
        }

        print("Retry-After parsing")
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        check(RetryPolicy.retryAt(header: "120", now: t0) == t0.addingTimeInterval(120), "seconds")
        check(RetryPolicy.retryAt(header: nil, now: t0) == t0.addingTimeInterval(RetryPolicy.defaultWait), "missing → default wait")
        check(RetryPolicy.retryAt(header: "soon", now: t0) == t0.addingTimeInterval(RetryPolicy.defaultWait), "garbage → default wait")
        check(RetryPolicy.retryAt(header: "0", now: t0) == t0.addingTimeInterval(RetryPolicy.minimumWait), "0 → minimum wait")
        check(RetryPolicy.retryAt(header: "-5", now: t0) == t0.addingTimeInterval(RetryPolicy.defaultWait), "negative → default wait")
        check(RetryPolicy.retryAt(header: "99999999", now: t0) == t0.addingTimeInterval(RetryPolicy.maximumWait), "huge → capped")
        let httpDate = "Fri, 15 Jan 2027 08:05:00 GMT"
        let parsed = RetryPolicy.retryAt(header: httpDate, now: Date(timeIntervalSince1970: 1_799_999_000))
        check(parsed.timeIntervalSince(Date(timeIntervalSince1970: 1_799_999_000)) <= RetryPolicy.maximumWait, "HTTP date is accepted and capped")
        let near = RetryPolicy.retryAt(header: "Fri, 15 Jan 2027 08:07:00 GMT", now: RetryPolicy.httpDate("Fri, 15 Jan 2027 08:05:00 GMT")!)
        check(near == RetryPolicy.httpDate("Fri, 15 Jan 2027 08:07:00 GMT"), "HTTP date two minutes ahead → that time")

        print("Store: shuffled operation orders (fixed seeds)")
        await shuffled()
    }

    /// Random interleavings of triggers, answers, failures, disconnects and reconnects.
    /// Invariants: never more than one live request; nothing shown after disconnect; the value shown
    /// always comes from the newest answered request of the current connection.
    @MainActor static func shuffled() async {
        var violations: [String] = []
        for seed in 1...150 {
            var rng = SeededRNG(seed: UInt64(seed))
            let (st, b, t, s) = make()
            var connectedAt = 0          // index in b.calls where the current connection's requests begin
            var newestShown = -1
            for step in 0..<30 {
                switch rng.next() % 7 {
                case 0: st.refresh(.claude)
                case 1: st.refresh(.claude, manual: true)
                case 2: st.refreshAll()
                case 3, 4:
                    let open = b.calls.indices.filter { b.calls[$0].cont != nil }
                    if let i = open.randomElement(using: &rng) {
                        if rng.next() % 3 == 0 { b.fail(b.calls[i], ProviderError(message: "x", kind: .generic)) }
                        else { b.succeed(b.calls[i], used: Double(i), at: t.now) }
                    }
                case 5: st.disconnect(.claude)
                default: if !s.isConnected(.claude) { st.useCLI(.claude); connectedAt = b.calls.count }
                }
                await settle()
                let liveOpen = b.calls.indices.filter { $0 >= connectedAt && b.calls[$0].cont != nil }.count
                if s.isConnected(.claude) && liveOpen > 1 { violations.append("seed \(seed) step \(step): \(liveOpen) live requests") }
                if !s.isConnected(.claude) && st.entries[.claude] != nil { violations.append("seed \(seed) step \(step): data shown while disconnected") }
                if let u = used(st) {
                    let idx = Int(u)
                    if idx < connectedAt { violations.append("seed \(seed) step \(step): shows an answer from before the reconnect") }
                    if idx < newestShown { violations.append("seed \(seed) step \(step): went back to an older answer") }
                    newestShown = max(newestShown, idx)
                } else { newestShown = s.isConnected(.claude) ? newestShown : -1 }
                if !s.isConnected(.claude) { newestShown = -1 }
            }
            b.drain(); await settle()
        }
        check(violations.isEmpty, "150 seeds × 30 steps: no stale value, no double request, nothing after disconnect"
              + (violations.isEmpty ? "" : " — first: \(violations[0]) (\(violations.count) total)"))
    }
}

/// Small deterministic PRNG so every run explores the same interleavings.
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}

enum CredentialTests {
    /// A fake Claude Code login store. Tokens here are made-up strings, never real ones.
    final class FakeLogin {
        var version: Date? = Date(timeIntervalSince1970: 1_800_000_000)
        var token = "fake-token-A"
        var readable = true
        var reads = 0
        var source: ClaudeProvider.CredentialSource {
            ClaudeProvider.CredentialSource(
                version: { [unowned self] in self.version },
                readSecret: { [unowned self] _ in
                    self.reads += 1
                    guard self.readable else { return (nil, errSecInteractionNotAllowed) }
                    let json = #"{"claudeAiOauth":{"accessToken":"\#(self.token)","expiresAt":4102444700000}}"#
                    return (Data(json.utf8), errSecSuccess)
                },
                fileDate: { nil }, readFile: { nil })
        }
    }

    static func run() {
        print("Claude CLI login cache")
        let login = FakeLogin()
        let provider = ClaudeProvider(source: login.source)
        check((try? provider.tokenForTesting()) == "fake-token-A", "reads the current login")
        _ = try? provider.tokenForTesting()
        check(login.reads == 1, "unchanged login → cached, not read again")
        login.version = login.version!.addingTimeInterval(60); login.token = "fake-token-B"
        check((try? provider.tokenForTesting()) == "fake-token-B", "Claude Code switched account → the new account is used at once")
        login.version = login.version!.addingTimeInterval(60); login.token = "fake-token-C"; login.readable = false
        var kind: ProviderError.Kind?
        do { _ = try provider.tokenForTesting() } catch let e as ProviderError { kind = e.kind } catch {}
        check(kind == .needsApproval, "changed login that can't be read → asks for approval, never falls back to the old token")
        login.readable = true
        provider.resetCache()
        let before = login.reads
        _ = try? provider.tokenForTesting()
        check(login.reads == before + 1, "disconnect clears the app's cache (next check reads again)")
        login.version = nil
        var missing: ProviderError.Kind?
        do { _ = try provider.tokenForTesting() } catch let e as ProviderError { missing = e.kind } catch {}
        check(missing == .cliMissing, "logged out of Claude Code → not shown with the old token")
    }
}

enum OriginTests {
    static func run() {
        print("Login and usage-check address rules")
        func off(_ s: String, _ p: Provider = .codex) -> Bool { WebOrigin.isOfficial(URL(string: s), for: p) }
        check(off("https://chatgpt.com/"), "https://chatgpt.com → official")
        check(off("https://chatgpt.com/auth/login?next=/"), "path and query are fine")
        check(off("https://CHATGPT.com/"), "host is case-insensitive")
        check(off("https://claude.ai/new", .claude), "https://claude.ai → official for Claude")
        check(!off("https://claude.ai/", .codex), "the other service's host isn't official for this one")
        check(!off("https://evilchatgpt.com/"), "look-alike suffix (evilchatgpt.com) → refused")
        check(!off("https://chatgpt.com.evil.com/"), "look-alike prefix → refused")
        check(!off("https://sub.chatgpt.com/"), "subdomain → refused (not needed for usage)")
        check(!off("http://chatgpt.com/"), "plain http → refused")
        check(!off("https://chatgpt.com:8443/"), "non-standard port → refused")
        check(off("https://chatgpt.com:443/"), "explicit 443 → official")
        check(!off("https://user:pass@chatgpt.com/"), "URL with user info → refused")
        check(!off("file:///etc/hosts"), "file: → refused")
        check(!off("javascript:alert(1)"), "javascript: → refused")
        check(!off("data:text/html,hi"), "data: → refused")
        check(!WebOrigin.isOfficial(nil, for: .codex), "no URL → refused")
        func kind(_ s: String) -> WebOrigin.Kind { WebOrigin.classify(URL(string: s), for: .codex) }
        check(kind("https://accounts.google.com/o/oauth2/v2/auth") == .identityProvider, "Google sign-in page → named as sign-in step")
        check(kind("https://appleid.apple.com/auth/authorize") == .identityProvider, "Apple sign-in page → named as sign-in step")
        check(kind("https://auth.openai.com/log-in") == .identityProvider, "OpenAI auth page → named as sign-in step")
        check(kind("https://accounts.google.com.evil.com/") == .unknown, "look-alike of a sign-in provider → warning")
        check(kind("http://accounts.google.com/") == .insecure, "http sign-in page → warning")
        check(kind("https://example.com/") == .unknown, "any other site → warning")
    }
}

enum UpdaterTests {
    static func run() {
        print("Updater: versions and release info")
        check(Updater.isNewer("1.2.0", than: "1.1.2"), "1.2.0 > 1.1.2")
        check(Updater.isNewer("1.10.0", than: "1.9.9"), "1.10.0 > 1.9.9 (numeric, not text)")
        check(!Updater.isNewer("1.1.2", than: "1.1.2"), "same version is not newer")
        check(!Updater.isNewer("1.1.1", than: "1.1.2"), "older is not newer")
        check(Updater.isNewer("2.0", than: "1.9.9"), "missing parts count as 0")
        func rel(_ json: String) -> Updater.Release? { Updater.parseRelease(Data(json.utf8)) }
        let ok = rel(#"{"tag_name":"v1.2.0","draft":false,"prerelease":false,"html_url":"https://github.com/seanwoo-personal/ai-usage/releases/tag/v1.2.0"}"#)
        check(ok?.version == "1.2.0" && ok?.tag == "v1.2.0", "published release is read")
        check(rel(#"{"tag_name":"v1.2.0","draft":true,"html_url":"https://github.com/x"}"#) == nil, "draft is ignored")
        check(rel(#"{"tag_name":"v1.2.0","prerelease":true,"html_url":"https://github.com/x"}"#) == nil, "pre-release is ignored")
        check(rel(#"{"tag_name":"1.2.0;rm -rf","html_url":"https://github.com/x"}"#) == nil, "malformed tag is ignored")
        check(rel(#"{"tag_name":"v1.2.0","html_url":"https://evil.example/x"}"#) == nil, "release page not on github.com is ignored")
        check(rel("not json") == nil, "garbage is ignored")
    }
}

enum SystemTests {
    static func run() {
        print("System monitor calculations")
        typealias T = SystemMath.CPUTicks
        check(SystemMath.cpuUsage(from: T(user: 100, system: 50, idle: 850, nice: 0), to: T(user: 130, system: 70, idle: 1000, nice: 0)) == 25,
              "CPU: 50 busy of 200 ticks → 25%")
        check(SystemMath.cpuUsage(from: T(user: 1, system: 1, idle: 1, nice: 0), to: T(user: 1, system: 1, idle: 1, nice: 0)) == nil, "CPU: no time passed → no reading")
        check(SystemMath.cpuUsage(from: T(user: 10, system: 1, idle: 1, nice: 0), to: T(user: 5, system: 1, idle: 9, nice: 0)) == nil, "CPU: counters went backwards → no reading")

        let gb: UInt64 = 1 << 30, page: UInt64 = 16_384
        func pages(_ bytes: UInt64) -> UInt64 { bytes / page }
        let m = SystemMath.Memory(pageSize: page, active: pages(8 * gb), inactive: pages(6 * gb), speculative: pages(1 * gb),
                                  wired: pages(3 * gb), compressed: pages(2 * gb), purgeable: pages(1 * gb), external: pages(1 * gb),
                                  physical: 24 * gb)
        check(SystemMath.memoryUsedPercent(m).map { abs($0 - 75) < 0.01 } == true, "RAM: Stats formula (18 of 24 GB) → 75%")
        var free = m; free.purgeable = pages(30 * gb)
        check(SystemMath.memoryUsedPercent(free) == 0, "RAM: more reclaimable than used → 0%, not negative")
        var huge = m; huge.active = .max
        check(SystemMath.memoryUsedPercent(huge) == nil, "RAM: overflowing counters → no reading (no crash)")
        var noRam = m; noRam.physical = 0
        check(SystemMath.memoryUsedPercent(noRam) == nil, "RAM: unknown total → no reading")

        check(SystemMath.diskUsedPercent(total: 1000, available: 330) == 67, "SSD: 670 of 1000 used → 67%")
        check(SystemMath.diskUsedPercent(total: 0, available: 0) == nil, "SSD: zero size → no reading")
        check(SystemMath.diskUsedPercent(total: 100, available: 200) == nil, "SSD: more free than total → no reading")

        typealias N = SystemMath.NetCounters
        let r = SystemMath.networkRate(from: N(sent: 1000, received: 5000), to: N(sent: 3000, received: 9000), seconds: 2)
        check(r?.up == 1000 && r?.down == 2000, "network: bytes per second from counter deltas")
        check(SystemMath.networkRate(from: N(sent: 9000, received: 9000), to: N(sent: 10, received: 10), seconds: 2) == nil,
              "network: counters reset (sleep, interface change) → no reading, not a huge number")
        check(SystemMath.networkRate(from: N(sent: 0, received: 0), to: N(sent: 10, received: 10), seconds: 0.01) == nil,
              "network: too short an interval → no reading")

        check(SystemMath.rateText(0) == "0 KB/s", "speed text: 0 KB/s")
        check(SystemMath.rateText(999 * 1024) == "999 KB/s", "speed text: 999 KB/s")
        check(SystemMath.rateText(1.4 * 1024 * 1024) == "1.4 MB/s", "speed text: 1.4 MB/s")
        check(SystemMath.rateText(120 * 1024 * 1024) == "120 MB/s", "speed text: 120 MB/s")
        check(SystemMath.rateText(2.5 * 1024 * 1024 * 1024) == "2.5 GB/s", "speed text: 2.5 GB/s")
        check(SystemMath.rateText(nil) == "– KB/s" && SystemMath.rateText(.nan) == "– KB/s" && SystemMath.rateText(-5) == "– KB/s",
              "speed text: missing or invalid → dash")
        check(SystemMath.percentText(nil) == "–" && SystemMath.percentText(.infinity) == "–" && SystemMath.percentText(150) == "100%",
              "percent text: missing, infinite and out-of-range values are safe")
        check(SystemStatusImage.render(.init(), metrics: SystemStatusImage.Metric.allCases) != nil, "menu bar image draws with no readings yet")
        check(SystemStatusImage.render(.init(), metrics: []) == nil, "no metrics chosen → no system item")

        print("System detail popovers")
        let b = SystemMath.cpuBreakdown(from: T(user: 100, system: 50, idle: 850, nice: 0), to: T(user: 120, system: 70, idle: 1000, nice: 10))
        check(b == .init(user: 15, system: 10, idle: 75), "CPU detail: user (with nice) / system / idle shares of 200 ticks")
        check(SystemMath.cpuBreakdown(from: T(user: 9, system: 0, idle: 0, nice: 0), to: T(user: 1, system: 0, idle: 0, nice: 0)) == nil,
              "CPU detail: counters went backwards → no reading")
        let cores = SystemMath.coreUsage(from: [T(user: 0, system: 0, idle: 0, nice: 0), T(user: 0, system: 0, idle: 0, nice: 0)],
                                         to: [T(user: 50, system: 0, idle: 50, nice: 0), T(user: 0, system: 0, idle: 0, nice: 0)])
        check(cores.count == 2 && cores[0] == 50 && cores[1] == nil, "cores: per-core usage; an idle-less core gives no reading")
        check(SystemMath.coreUsage(from: [], to: [T(user: 1, system: 0, idle: 1, nice: 0)]) == [nil], "cores: core count changed → no readings")

        if let mb = SystemMath.memoryBreakdown(m) {
            check(mb.used == 18 * gb && mb.wired == 3 * gb && mb.compressed == 2 * gb && mb.app == 13 * gb,
                  "RAM detail: used 18 GB = app 13 + wired 3 + compressed 2")
            check(mb.cache == 2 * gb && mb.free == 6 * gb && mb.total == 24 * gb, "RAM detail: cache = purgeable + file-backed; free = total − used")
        } else { check(false, "RAM detail: breakdown available") }
        var tight = m; tight.wired = pages(20 * gb); tight.compressed = pages(10 * gb)
        check(SystemMath.memoryBreakdown(tight)?.app == 0, "RAM detail: wired + compressed above used → app 0, not negative")

        check(SystemMath.rate(from: 1000, to: 5000, seconds: 2) == 2000, "disk speed: bytes per second from counter deltas")
        check(SystemMath.rate(from: 5000, to: 1000, seconds: 2) == nil, "disk speed: counters reset → no reading")
        check(SystemMath.rate(from: 0, to: 10, seconds: 0.1) == nil, "disk speed: too short an interval → no reading")

        check(SystemMath.bytesText(0) == "0 B" && SystemMath.bytesText(512) == "512 B", "size text: bytes")
        check(SystemMath.bytesText(1.5 * 1024 * 1024 * 1024) == "1.5 GB", "size text: 1.5 GB")
        check(SystemMath.bytesText(926 * 1024 * 1024 * 1024) == "926 GB", "size text: 926 GB")
        check(SystemMath.bytesText(nil) == "–" && SystemMath.bytesText(-1) == "–" && SystemMath.bytesText(.nan) == "–", "size text: invalid → dash")

        let ps = SystemMath.parsePS("""
          412  52.3 WindowServer
           88   0,5 Google Chrome Helper (Renderer)
          bad line
            7  -1 negative
        """)
        check(ps.map(\.pid) == [412, 88] && ps[1].name == "Google Chrome Helper (Renderer)" && ps[1].value == 0.5,
              "ps: pid, value (comma decimals too) and names with spaces; bad lines skipped")
        check(SystemMath.parsePS("  1  2048 kernel_task", valueScale: 1024).first?.value == 2_097_152, "ps: RSS kilobytes scaled to bytes")

        let before: [Int32: (name: String, bytes: UInt64)] = [1: ("a", 100), 2: ("b", 100), 3: ("c", 500), 4: ("old", 0)]
        let after: [Int32: (name: String, bytes: UInt64)] = [1: ("a", 300), 2: ("b", 100), 3: ("c", 100), 4: ("new", 900), 5: ("d", 9)]
        let top = SystemMath.topDiskProcesses(from: before, to: after, seconds: 2)
        check(top.map(\.pid) == [1] && top.first?.value == 100,
              "disk top: only processes that did I/O; new, reused-pid and reset counters left out")

        var hist: [Double] = []
        for i in 0..<70 { hist = SystemMath.appending(Double(i), to: hist) }
        check(hist.count == 60 && hist.first == 10 && hist.last == 69, "history keeps the newest 60 samples")
        check(SystemMath.appending(.nan, to: []) == [0] && SystemMath.appending(nil, to: []) == [0], "history: missing or invalid sample → 0")

        check(SystemMath.pressureText(.normal, freePercent: 47) == L.t("정상 (여유 47%)", "Normal (47% free)")
              && SystemMath.pressureText(.normal, freePercent: nil) == "–" && SystemMath.pressureText(.normal, freePercent: 500) == "–",
              "memory pressure text")
        check(SystemMath.uptimeText(3 * 86_400 + 4 * 3600) == L.t("3일 4시간", "3d 4h"), "uptime text")

        print("Strain colours")
        check(SystemMath.cpuLevel(recent: [10, 10, 10, 100, 10]) == .normal, "CPU colour: one brief spike stays normal")
        check(SystemMath.cpuLevel(recent: [5, 5, 75, 75, 75, 75, 75]) == .warning, "CPU colour: 5-second average ≥70% → yellow (older samples ignored)")
        check(SystemMath.cpuLevel(recent: [95, 92, 90, 91, 99]) == .critical, "CPU colour: 5-second average ≥90% → red")
        check(SystemMath.cpuLevel(recent: []) == .normal && SystemMath.cpuLevel(recent: [.nan, .infinity]) == .normal,
              "CPU colour: no or invalid samples → normal")
        check(SystemMath.memoryLevel(freePercent: 47, pressure: 2) == .normal,
              "RAM colour: plenty free → normal even if the kernel's lingering 'warning' flag is set")
        check(SystemMath.memoryLevel(freePercent: 19, pressure: 1) == .warning && SystemMath.memoryLevel(freePercent: 9, pressure: 1) == .critical,
              "RAM colour: under 20% free → yellow, under 10% → red")
        check(SystemMath.memoryLevel(freePercent: 50, pressure: 4) == .critical, "RAM colour: kernel critical → red")
        check(SystemMath.memoryLevel(freePercent: nil, pressure: nil) == .normal && SystemMath.memoryLevel(freePercent: -3, pressure: nil) == .normal,
              "RAM colour: unknown → normal")
        check(SystemMath.diskLevel(percent: 89.9) == .normal && SystemMath.diskLevel(percent: 90) == .warning
              && SystemMath.diskLevel(percent: 95) == .critical && SystemMath.diskLevel(percent: .nan) == .normal, "SSD colour: 90% / 95% used")
        var strained = SystemMonitor.Reading(cpu: 95, memory: 80, disk: 50)
        strained.cpuLevel = .critical
        check(SystemStatusImage.render(strained, metrics: [.cpu], ink: .black, colors: true) != nil, "coloured menu bar image draws")
        check(SystemStatusImage.alertColor(.normal, dark: true) == nil && SystemStatusImage.alertColor(.warning, dark: false) != nil,
              "normal readings keep the menu bar colour")
        let colorSettings = AppSettings.forTesting()
        check(colorSettings.systemColors, "strain colours are on by default")
    }
}
