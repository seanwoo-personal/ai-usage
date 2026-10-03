import AppKit
import SwiftUI
import WebKit

/// Which pages count as the service itself. Checked before deciding "logged in" and before
/// running the usage script, so a look-alike host, plain http, another port or a URL with user
/// info is never trusted.
enum WebOrigin {
    static func host(for p: Provider) -> String { p == .claude ? "claude.ai" : "chatgpt.com" }

    /// Sign-in providers these sites hand off to. Used only to word the login window's notice
    /// (navigation to them is allowed, as in any browser); they are never trusted for usage checks.
    static let identityProviders: Set<String> = ["accounts.google.com", "appleid.apple.com", "auth.openai.com",
                                                "login.microsoftonline.com", "login.live.com"]

    enum Kind: Equatable { case official, identityProvider, unknown, insecure }

    private static func parts(_ url: URL?) -> (scheme: String, host: String)? {
        guard let url, let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = c.scheme?.lowercased(), let host = c.host?.lowercased(), !host.isEmpty,
              c.user == nil, c.password == nil else { return nil }
        if let port = c.port, port != (scheme == "https" ? 443 : 80) { return nil }
        return (scheme, host)
    }

    /// Exactly https://claude.ai or https://chatgpt.com (default port, no user info).
    static func isOfficial(_ url: URL?, for p: Provider) -> Bool {
        guard let (scheme, host) = parts(url) else { return false }
        return scheme == "https" && host == Self.host(for: p)
    }

    static func classify(_ url: URL?, for p: Provider) -> Kind {
        if isOfficial(url, for: p) { return .official }
        guard let (scheme, host) = parts(url) else { return .unknown }
        guard scheme == "https" else { return .insecure }
        return identityProviders.contains(host) ? .identityProvider : .unknown
    }
}

/// A claude.ai / chatgpt.com login kept inside the app (WebKit's own website data store).
/// Usage is fetched from within a page on that site, so cookies and tokens never pass through our code.
@MainActor
final class WebAccount: NSObject, WKNavigationDelegate {
    let provider: Provider
    private var webView: WKWebView?
    private var loadedAt: Date?
    private var loadWaiters: [CheckedContinuation<Void, Error>] = []
    /// The page load the waiters belong to. Callbacks for any other load (an earlier page,
    /// a discarded web view) are ignored.
    private var pendingNavigation: ObjectIdentifier?

    /// Plain Safari user agent: some sign-in pages (e.g. Google) refuse embedded browsers otherwise.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"

    init(provider: Provider) { self.provider = provider }

    var origin: URL { URL(string: provider == .claude ? "https://claude.ai" : "https://chatgpt.com")! }
    var loginURL: URL { URL(string: provider == .claude ? "https://claude.ai/login" : "https://chatgpt.com/auth/login")! }
    /// A small same-origin document to run fetches from.
    private var anchorURL: URL { origin.appendingPathComponent("robots.txt") }

    static func configuration() -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = .default()
        return c
    }

    // MARK: - Usage

    func fetch() async throws -> ProviderSnapshot {
        let result = try await run(provider == .claude ? Self.claudeJS : Self.codexJS)
        let status = Parse.int(result["status"]) ?? 0
        let body = Data(((result["body"] as? String) ?? "").utf8)
        let isHTML = ((result["type"] as? String) ?? "").contains("html")

        switch status {
        case 200 where !isHTML: break
        case 0: throw ProviderError.wrap(URLError(.notConnectedToInternet))
        case 401, 403, 200:
            throw isHTML
                ? ProviderError(message: L.t(
                    "\(provider.website)의 보안 확인 때문에 잠시 막혔어요. 버튼을 눌러 로그인 창을 한 번 열면 풀려요.",
                    "\(provider.website) asked for a security check. Open the login window once to clear it."), kind: .needsLogin)
                : ProviderError(message: L.t(
                    "\(provider.accountName) 로그인이 만료됐어요. 다시 로그인하면 바로 이어서 표시돼요.",
                    "Your \(provider.accountName) login has expired. Log in again to continue."), kind: .needsLogin)
        case 404:
            throw ProviderError(message: L.t(
                "이 계정에서 사용량 정보를 찾지 못했어요. 구독 중인 계정으로 로그인했는지 확인해 주세요.",
                "No usage information for this account. Check that you logged in with your subscribed account."), kind: .noLimits)
        case 429: throw ProviderError.rateLimited(until: RetryPolicy.retryAt(header: result["retryAfter"] as? String, now: Date()))
        default: throw ProviderError.server(status)
        }

        if provider == .claude {
            let caps = (result["caps"] as? [String]) ?? []
            let plan = caps.contains("claude_max") ? "max" : caps.contains("claude_pro") ? "pro" : nil
            var snap = try ClaudeProvider.parseUsage(body, plan: plan)
            snap.source = .web
            snap.accountKey = AccountKey.make(.claude, id: result["account"] as? String)
            return snap
        }
        guard var snap = CodexProvider.parseLive(body) else {
            throw ProviderError(message: L.t(
                "이 ChatGPT 계정에는 Codex 사용 한도 정보가 없어요. Plus·Pro 등 유료 요금제에서 제공돼요.",
                "This ChatGPT account has no Codex limits. They come with paid plans such as Plus or Pro."), kind: .noLimits)
        }
        snap.source = .web
        snap.accountKey = AccountKey.make(.codex, id: result["account"] as? String)
        return snap
    }

    func isLoggedIn() async -> Bool {
        let js = provider == .claude
            ? "const r = await fetch('/api/organizations', {credentials: 'include'}); if (!r.ok) return false; const o = await r.json(); return Array.isArray(o) && o.length > 0;"
            : "const r = await fetch('/api/auth/session', {credentials: 'include'}); if (!r.ok) return false; const s = await r.json(); return !!(s && s.accessToken);"
        guard let wv = try? await anchor(), WebOrigin.isOfficial(wv.url, for: provider) else { return false }
        return ((try? await wv.callAsyncJavaScript(js, contentWorld: .defaultClient)) as? Bool) ?? false
    }

    /// Sign-in providers' data is shared by both services, so it's erased only on request.
    static let sharedSignInDomains = ["google.com", "apple.com", "live.com", "microsoftonline.com", "microsoft.com"]

    /// Forgets this site's login (cookies, storage) from the app; the other service's is kept.
    func logOut(clearSharedSignIn: Bool = false) async {
        discardWebView(URLError(.cancelled))
        let store = WKWebsiteDataStore.default()
        var domains = provider == .claude ? ["claude.ai", "anthropic.com"] : ["chatgpt.com", "openai.com"]
        if clearSharedSignIn { domains += Self.sharedSignInDomains }
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let mine = records.filter { r in domains.contains { r.displayName.hasSuffix($0) } }
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: mine)
    }

    // MARK: - Page plumbing

    private func run(_ js: String) async throws -> [String: Any] {
        let wv = try await anchor()
        guard WebOrigin.isOfficial(wv.url, for: provider) else {
            discardWebView(URLError(.cancelled))
            throw ProviderError(message: L.t(
                "\(provider.website)가 아닌 주소로 이동돼서 조회를 멈췄어요. 다시 로그인해 주세요.",
                "The page moved away from \(provider.website), so the check stopped. Please log in again."), kind: .needsLogin)
        }
        let outcome: Result<Any?, Error>? = await withTimeout(20) {
            do { return .success(try await wv.callAsyncJavaScript(js, contentWorld: .defaultClient)) } catch { return .failure(error) }
        } ?? nil
        guard case .success(let raw)? = outcome else {
            // A script that timed out may still be running: drop this web view instead of reusing it,
            // so repeated timeouts can't pile up pages or answers.
            discardWebView(URLError(.timedOut))
            NSLog("AIUsage: \(provider.rawValue) web fetch script \(outcome == nil ? "timed out" : "failed")")
            throw ProviderError.wrap(URLError(.timedOut))
        }
        if let s = raw as? String, let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] {
            NSLog("AIUsage: \(provider.rawValue) web fetch -> status \(obj["status"] ?? "?") type \(obj["type"] ?? "?")")
        }
        guard let s = raw as? String, let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else {
            throw ProviderError(message: L.t("사용량 응답을 해석하지 못했어요. 잠시 후 다시 시도해요.", "Couldn't read the usage response. Will retry shortly."))
        }
        return obj
    }

    /// Loads (or reuses, for up to 30 minutes) a same-origin page to run fetches from.
    private func anchor() async throws -> WKWebView {
        if let wv = webView, let at = loadedAt, Date().timeIntervalSince(at) < 1800, WebOrigin.isOfficial(wv.url, for: provider) {
            return wv
        }
        let wv = webView ?? {
            let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: Self.configuration())
            w.customUserAgent = Self.userAgent
            w.navigationDelegate = self
            return w
        }()
        webView = wv
        if loadWaiters.isEmpty {
            pendingNavigation = wv.load(URLRequest(url: anchorURL, timeoutInterval: 20)).map(ObjectIdentifier.init)
        }
        let loaded: Bool? = await withTimeout(20) {
            do {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    self.loadWaiters.append(cont)
                }
                return true
            } catch { return false }
        }
        guard loaded == true else {
            // Timed out (nil) or failed: release every waiter exactly once and drop this web view.
            discardWebView(URLError(.timedOut))
            throw ProviderError.wrap(URLError(.timedOut))
        }
        loadedAt = Date()
        return wv
    }

    /// Stops and forgets the hidden web view; anyone still waiting for its page gets `error`.
    private func discardWebView(_ error: Error) {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        loadedAt = nil
        pendingNavigation = nil
        finishLoad(error)
    }

    private func finishLoad(_ error: Error?) {
        let waiters = loadWaiters
        loadWaiters = []
        for w in waiters {
            if let error { w.resume(throwing: ProviderError.wrap(error)) } else { w.resume() }
        }
    }

    /// Only the load we're waiting for, in the web view we still hold, may finish the wait.
    private func navigationEnded(_ id: ObjectIdentifier?, in view: WKWebView, error: Error?) {
        guard let id, id == pendingNavigation, view === webView else { return }
        pendingNavigation = nil
        finishLoad(error)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let id = navigation.map(ObjectIdentifier.init)
        Task { @MainActor in self.navigationEnded(id, in: webView, error: nil) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let id = navigation.map(ObjectIdentifier.init)
        Task { @MainActor in self.navigationEnded(id, in: webView, error: error) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let id = navigation.map(ObjectIdentifier.init)
        Task { @MainActor in self.navigationEnded(id, in: webView, error: error) }
    }

    // Returned as a JSON string: {status, type, body, caps?}. status 0 = network failure.
    private static let claudeJS = """
    try {
      const orgsRes = await fetch('/api/organizations', {credentials: 'include'});
      const orgsType = orgsRes.headers.get('content-type') || '';
      if (!orgsRes.ok || !orgsType.includes('json')) return JSON.stringify({status: orgsRes.status, type: orgsType});
      const orgs = await orgsRes.json();
      if (!Array.isArray(orgs) || orgs.length === 0) return JSON.stringify({status: 401, type: 'json'});
      const m = document.cookie.match(/(?:^|; )lastActiveOrg=([^;]+)/);
      const active = m ? decodeURIComponent(m[1]) : null;
      const paid = o => (o.capabilities || []).some(c => c === 'claude_max' || c === 'claude_pro');
      const org = orgs.find(o => o.uuid === active && paid(o)) || orgs.find(paid) || orgs.find(o => o.uuid === active) || orgs[0];
      const r = await fetch('/api/organizations/' + org.uuid + '/usage', {credentials: 'include'});
      return JSON.stringify({status: r.status, type: r.headers.get('content-type') || '', retryAfter: r.headers.get('retry-after'), body: await r.text(), caps: org.capabilities || [], account: org.uuid});
    } catch (e) {
      return JSON.stringify({status: 0, error: String(e)});
    }
    """

    private static let codexJS = """
    try {
      const s = await fetch('/api/auth/session', {credentials: 'include'});
      const sType = s.headers.get('content-type') || '';
      if (!s.ok || !sType.includes('json')) return JSON.stringify({status: s.status === 200 ? 403 : s.status, type: sType});
      const sess = await s.json();
      if (!sess || !sess.accessToken) return JSON.stringify({status: 401, type: 'json'});
      const headers = {Authorization: 'Bearer ' + sess.accessToken};
      if (sess.account && sess.account.id) headers['ChatGPT-Account-Id'] = sess.account.id;
      const r = await fetch('/backend-api/wham/usage', {headers, credentials: 'include'});
      return JSON.stringify({status: r.status, type: r.headers.get('content-type') || '', retryAfter: r.headers.get('retry-after'), body: await r.text(), account: (sess.account && sess.account.id) || null});
    } catch (e) {
      return JSON.stringify({status: 0, error: String(e)});
    }
    """
}

// MARK: - Login window

/// A normal sign-in page for claude.ai / chatgpt.com with a short explanation on top.
/// Closes itself as soon as the login is detected.
@MainActor
final class LoginWindow: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private static var openWindows: [Provider: LoginWindow] = [:]

    private let account: WebAccount
    private let window: NSWindow
    private let webView: WKWebView
    private let state = LoginHeaderState()
    private var poll: Timer?
    private var popups: [NSWindow] = []
    private var completion: ((Bool) -> Void)?

    /// Closes the login window for `p` (and its popups) without reporting success or failure.
    static func dismiss(_ p: Provider) {
        guard let lw = openWindows[p] else { return }
        lw.completion = nil
        lw.window.close()
    }

    static func show(for account: WebAccount, completion: @escaping (Bool) -> Void) {
        if let existing = openWindows[account.provider] {
            existing.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let lw = LoginWindow(account: account, completion: completion)
        openWindows[account.provider] = lw
        lw.window.center()
        lw.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(account: WebAccount, completion: @escaping (Bool) -> Void) {
        self.account = account
        self.completion = completion
        webView = WKWebView(frame: .zero, configuration: WebAccount.configuration())
        webView.customUserAgent = WebAccount.userAgent
        #if DEBUG
        if #available(macOS 13.3, *) { webView.isInspectable = true }   // Web Inspector only in development builds
        #endif
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 760),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()

        let p = account.provider
        window.title = L.t("\(p.displayName) 로그인 — AI Usage", "\(p.displayName) login — AI Usage")
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self

        let header = NSHostingView(rootView: LoginHeader(provider: p, state: state, cancel: { [weak self] in self?.window.close() }))
        header.translatesAutoresizingMaskIntoConstraints = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(header)
        root.addSubview(webView)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            webView.topAnchor.constraint(equalTo: header.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        window.contentView = root

        state.loading = true
        webView.load(URLRequest(url: account.loginURL))
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.checkLogin() }
        }
    }

    private func checkLogin() async {
        guard completion != nil, !state.checking else { return }
        state.checking = true
        defer { state.checking = false }
        if await loggedInHere() {
            state.done = true
            poll?.invalidate()
            let done = completion
            completion = nil
            done?(true)
            try? await Task.sleep(nanoseconds: 900_000_000)
            window.close()
        }
    }

    /// Asks the site, from inside this login page, whether the session is valid.
    /// Logs only the status code and page path (never cookies or tokens).
    private func loggedInHere() async -> Bool {
        guard WebOrigin.isOfficial(webView.url, for: account.provider), let host = webView.url?.host else { return false }
        let js = account.provider == .claude
            ? "const r = await fetch('/api/organizations', {credentials: 'include'}); let n = 0; try { const o = await r.json(); n = Array.isArray(o) ? o.length : 0 } catch (e) {} return r.status + ':' + n;"
            : "const r = await fetch('/api/auth/session', {credentials: 'include'}); let n = 0; try { const s = await r.json(); n = (s && s.accessToken) ? 1 : 0 } catch (e) {} return r.status + ':' + n;"
        let result = await withTimeout(15) { [webView] in
            (try? await webView.callAsyncJavaScript(js, contentWorld: .defaultClient)) as? String
        } ?? nil
        NSLog("AIUsage: login check \(host)\(webView.url?.path ?? "") -> \(result ?? "no answer")")
        guard let parts = result?.split(separator: ":"), parts.count == 2 else { return false }
        return parts[0] == "200" && (Int(parts[1]) ?? 0) > 0
    }

    func windowWillClose(_ notification: Notification) {
        popups.forEach { $0.close() }
        popups.removeAll()
        poll?.invalidate()
        webView.stopLoading()
        completion?(false)
        completion = nil
        Self.openWindows[account.provider] = nil
    }

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in self.state.loading = true }
    }

    nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        Task { @MainActor in self.updatePageNotice() }
    }

    /// The notice under the title says where the user actually is, not just "official page".
    private func updatePageNotice() {
        state.pageKind = WebOrigin.classify(webView.url, for: account.provider)
        state.pageHost = webView.url?.host ?? ""
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.updatePageNotice()
            self.state.loading = false
            self.state.failed = false
            await self.checkLogin()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.state.loading = false
            if (error as NSError).code != NSURLErrorCancelled { self.state.failed = true }
        }
    }

    /// Sign-in popups (e.g. "Continue with Google") open in a real child window, like a browser does,
    /// so they can hand the result back to the login page and close themselves.
    nonisolated func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                             for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        MainActor.assumeIsolated {
            let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: configuration)
            popup.customUserAgent = WebAccount.userAgent
            popup.uiDelegate = self
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = L.t("로그인", "Sign in")
            w.isReleasedWhenClosed = false
            w.level = .floating
            w.contentView = popup
            if let frame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
                w.setFrameOrigin(NSPoint(x: window.frame.midX - 240 + 24, y: min(window.frame.midY - 320 - 24, frame.maxY - 660)))
            }
            w.makeKeyAndOrderFront(nil)
            popups.append(w)
            NSLog("AIUsage: login popup opened")
            return popup
        }
    }

    /// The popup called window.close() — normally right after finishing the sign-in.
    nonisolated func webViewDidClose(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            if let i = popups.firstIndex(where: { $0.contentView === webView }) {
                popups[i].close()
                popups.remove(at: i)
                NSLog("AIUsage: login popup closed")
            }
            Task { await self.checkLogin() }
        }
    }

    func reload() {
        state.failed = false
        webView.load(URLRequest(url: account.loginURL))
    }
}

@MainActor
final class LoginHeaderState: ObservableObject {
    @Published var loading = false
    @Published var checking = false
    @Published var failed = false
    @Published var done = false
    @Published var pageKind: WebOrigin.Kind = .official
    @Published var pageHost = ""
}

private struct LoginHeader: View {
    let provider: Provider
    @ObservedObject var state: LoginHeaderState
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProviderLogo(provider: provider, size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.done
                         ? L.t("로그인 완료! 사용량을 불러오고 있어요", "Logged in! Loading your usage…")
                         : L.t("\(provider.accountName)으로 로그인해 주세요", "Log in with your \(provider.accountName)"))
                        .font(.system(size: 14, weight: .semibold))
                    Text(L.t("평소처럼 \(provider.website)에 로그인하면 돼요. 로그인이 끝나면 이 창은 자동으로 닫혀요.",
                             "Log in to \(provider.website) as usual. This window closes by itself when you're done."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if state.loading || state.done { ProgressView().controlSize(.small) }
                Button(L.t("취소", "Cancel"), action: cancel)
            }
            if state.failed {
                Label(L.t("페이지를 불러오지 못했어요. 인터넷 연결을 확인한 뒤 창을 닫고 다시 시도해 주세요.",
                          "Couldn't load the page. Check your connection, then close and try again."),
                      systemImage: "wifi.exclamationmark")
                    .font(.caption).foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 4) {
                pageNotice
                Label(L.t("Google 로그인이 막히면 이메일로 로그인해 주세요.", "If Google sign-in is blocked, use email instead."),
                      systemImage: "lightbulb")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    @ViewBuilder private var pageNotice: some View {
        switch state.pageKind {
        case .official:
            Label(L.t("\(provider.website) 공식 페이지예요. 비밀번호는 이 페이지에 직접 입력되고, AI Usage는 읽거나 저장하지 않아요.",
                      "This is the official \(provider.website) page. Your password goes straight to it; AI Usage never reads or stores it."),
                  systemImage: "lock.shield")
        case .identityProvider:
            Label(L.t("로그인을 위해 \(state.pageHost)(으)로 이동했어요. 끝나면 \(provider.website)로 돌아와요.",
                      "Signing in through \(state.pageHost). You'll return to \(provider.website) afterwards."),
                  systemImage: "person.badge.key")
        case .unknown, .insecure:
            Label(L.t("지금 페이지(\(state.pageHost.isEmpty ? "알 수 없음" : state.pageHost))는 \(provider.website)가 아니에요. 주소를 확인하기 전에는 로그인 정보를 입력하지 마세요.",
                      "This page (\(state.pageHost.isEmpty ? "unknown" : state.pageHost)) isn't \(provider.website). Don't enter your login until you've checked the address."),
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }
}

/// Runs `work` but stops waiting after `seconds`, returning nil. (A task group would still wait
/// for a hung child, so this resumes on whichever finishes first.)
@MainActor
func withTimeout<T>(_ seconds: TimeInterval, _ work: @escaping @MainActor () async -> T) async -> T? {
    await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
        var finished = false   // only touched on the main thread
        Task { @MainActor in
            let value = await work()
            if !finished { finished = true; cont.resume(returning: value) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if !finished { finished = true; cont.resume(returning: nil) }
        }
    }
}
