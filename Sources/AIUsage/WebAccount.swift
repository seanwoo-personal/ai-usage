import AppKit
import SwiftUI
import WebKit

/// A claude.ai / chatgpt.com login kept inside the app (WebKit's own website data store).
/// Usage is fetched from within a page on that site, so cookies and tokens never pass through our code.
@MainActor
final class WebAccount: NSObject, WKNavigationDelegate {
    let provider: Provider
    private var webView: WKWebView?
    private var loadedAt: Date?
    private var loadWaiters: [CheckedContinuation<Void, Error>] = []

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
        case 429: throw ProviderError.rateLimited
        default: throw ProviderError.server(status)
        }

        if provider == .claude {
            let caps = (result["caps"] as? [String]) ?? []
            let plan = caps.contains("claude_max") ? "max" : caps.contains("claude_pro") ? "pro" : nil
            var snap = try ClaudeProvider.parseUsage(body, plan: plan)
            snap.source = .web
            return snap
        }
        guard var snap = CodexProvider.parseLive(body) else {
            throw ProviderError(message: L.t(
                "이 ChatGPT 계정에는 Codex 사용 한도 정보가 없어요. Plus·Pro 등 유료 요금제에서 제공돼요.",
                "This ChatGPT account has no Codex limits. They come with paid plans such as Plus or Pro."), kind: .noLimits)
        }
        snap.source = .web
        return snap
    }

    func isLoggedIn() async -> Bool {
        let js = provider == .claude
            ? "const r = await fetch('/api/organizations', {credentials: 'include'}); if (!r.ok) return false; const o = await r.json(); return Array.isArray(o) && o.length > 0;"
            : "const r = await fetch('/api/auth/session', {credentials: 'include'}); if (!r.ok) return false; const s = await r.json(); return !!(s && s.accessToken);"
        guard let wv = try? await anchor() else { return false }
        return ((try? await wv.callAsyncJavaScript(js, contentWorld: .defaultClient)) as? Bool) ?? false
    }

    /// Forgets this site's login (cookies, storage) from the app.
    func logOut() async {
        webView = nil
        loadedAt = nil
        let store = WKWebsiteDataStore.default()
        let domains = provider == .claude ? ["claude.ai", "anthropic.com"] : ["chatgpt.com", "openai.com"]
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let mine = records.filter { r in domains.contains { r.displayName.hasSuffix($0) } }
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: mine)
    }

    // MARK: - Page plumbing

    private func run(_ js: String) async throws -> [String: Any] {
        let wv = try await anchor()
        let outcome: Result<Any?, Error>? = await withTimeout(20) {
            do { return .success(try await wv.callAsyncJavaScript(js, contentWorld: .defaultClient)) } catch { return .failure(error) }
        } ?? nil
        guard case .success(let raw)? = outcome else {
            loadedAt = nil   // reload the page next time
            NSLog("AIUsage: \(provider.rawValue) web fetch script failed: \(outcome.map { "\($0)" } ?? "timed out")")
            throw ProviderError.wrap(URLError(.cannotLoadFromNetwork))
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
        if let wv = webView, let at = loadedAt, Date().timeIntervalSince(at) < 1800, wv.url?.host == origin.host { return wv }
        let wv = webView ?? {
            let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: Self.configuration())
            w.customUserAgent = Self.userAgent
            w.navigationDelegate = self
            return w
        }()
        webView = wv
        if loadWaiters.isEmpty { wv.load(URLRequest(url: anchorURL, timeoutInterval: 20)) }
        let loaded: Bool? = await withTimeout(20) {
            do {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    self.loadWaiters.append(cont)
                }
                return true
            } catch { return false }
        }
        guard loaded == true else {
            if loaded == nil { finishLoad(URLError(.timedOut)) }   // release any waiter left behind
            webView = nil
            throw ProviderError.wrap(URLError(.timedOut))
        }
        loadedAt = Date()
        return wv
    }

    private func finishLoad(_ error: Error?) {
        let waiters = loadWaiters
        loadWaiters = []
        for w in waiters {
            if let error { w.resume(throwing: ProviderError.wrap(error)) } else { w.resume() }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.finishLoad(nil) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finishLoad(error) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finishLoad(error) }
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
      return JSON.stringify({status: r.status, type: r.headers.get('content-type') || '', body: await r.text(), caps: org.capabilities || []});
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
      return JSON.stringify({status: r.status, type: r.headers.get('content-type') || '', body: await r.text()});
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
        if #available(macOS 13.3, *) { webView.isInspectable = true }
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
            Task { @MainActor in await self?.checkLogin() }
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
        guard let host = webView.url?.host, host.hasSuffix(account.origin.host ?? "") else { return false }
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

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
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
                Label(L.t("\(provider.website) 공식 페이지예요. 비밀번호는 이 페이지에 직접 입력되고, AI Usage는 읽거나 저장하지 않아요.",
                          "This is the official \(provider.website) page. Your password goes straight to it; AI Usage never reads or stores it."),
                      systemImage: "lock.shield")
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
