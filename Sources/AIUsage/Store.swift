import AppKit
import Combine
import ServiceManagement

final class AppSettings: ObservableObject {
    enum BarMode: String, CaseIterable, Identifiable {
        case weekly, session, both
        var id: String { rawValue }
        var title: String {
            switch self {
            case .weekly: return L.t("주간", "Weekly")
            case .session: return L.t("5시간", "5-hour")
            case .both: return L.t("둘 다", "Both")
            }
        }
    }

    private let d: UserDefaults

    /// Which limit each provider shows in the menu bar.
    @Published var barModes: [Provider: BarMode] {
        didSet { for (p, m) in barModes { d.set(m.rawValue, forKey: "barMode.\(p.rawValue)") } }
    }
    /// How each provider is connected. `.none` providers are never read or shown.
    @Published var connections: [Provider: Connection] {
        didSet { for (p, c) in connections { d.set(c.rawValue, forKey: "connection.\(p.rawValue)") } }
    }
    @Published var showRemaining: Bool { didSet { d.set(showRemaining, forKey: "showRemaining") } }
    @Published var showResetInBar: Bool { didSet { d.set(showResetInBar, forKey: "showResetInBar") } }
    /// Allowed refresh intervals. Anything else (a damaged or hand-edited setting) falls back to 3.
    static let refreshChoices = [1, 3, 5, 10, 15]
    static func validRefreshMinutes(_ v: Int) -> Int { refreshChoices.contains(v) ? v : 3 }

    @Published var refreshMinutes: Int {
        didSet {
            let valid = Self.validRefreshMinutes(refreshMinutes)
            if valid != refreshMinutes { refreshMinutes = valid }
            d.set(refreshMinutes, forKey: "refreshMinutes")
        }
    }
    @Published var onboarded: Bool { didSet { d.set(onboarded, forKey: "onboarded") } }

    init(defaults d: UserDefaults = .standard) {
        self.d = d
        d.register(defaults: ["showRemaining": true, "showResetInBar": true, "refreshMinutes": 3, "onboarded": false])
        barModes = Dictionary(uniqueKeysWithValues: Provider.allCases.map { p in
            (p, BarMode(rawValue: d.string(forKey: "barMode.\(p.rawValue)") ?? "") ?? .weekly)
        })
        connections = Dictionary(uniqueKeysWithValues: Provider.allCases.map { p in
            if let raw = d.string(forKey: "connection.\(p.rawValue)"), let c = Connection(rawValue: raw) { return (p, c) }
            // Earlier versions only knew "connected" = CLI login.
            let legacy = d.bool(forKey: p == .claude ? "connectedClaude" : "connectedCodex")
            return (p, legacy ? .cli : .none)
        })
        showRemaining = d.bool(forKey: "showRemaining")
        showResetInBar = d.bool(forKey: "showResetInBar")
        refreshMinutes = Self.validRefreshMinutes(d.integer(forKey: "refreshMinutes"))
        onboarded = d.bool(forKey: "onboarded") || d.bool(forKey: "connectedClaude") || d.bool(forKey: "connectedCodex")
    }

    /// Settings in a throwaway defaults domain, for tests.
    static func forTesting() -> AppSettings {
        let name = "aiusage.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return AppSettings(defaults: d)
    }

    func barMode(_ p: Provider) -> BarMode { barModes[p] ?? .weekly }
    func connection(_ p: Provider) -> Connection { connections[p] ?? .none }
    func isConnected(_ p: Provider) -> Bool { connection(p) != .none }

    /// Why the last "open at login" change didn't happen (shown under the toggle), or nil.
    @Published var loginItemMessage: String?

    /// Reading reflects the system state, so a refused change flips the toggle straight back.
    var launchAtLogin: Bool {
        get { LoginItem.isEnabled }
        set {
            objectWillChange.send()
            loginItemMessage = LoginItem.setEnabled(newValue)
        }
    }
}

@MainActor
final class UsageStore: ObservableObject {
    struct Entry {
        var snapshot: ProviderSnapshot?
        var error: ProviderError?
        var loading = false
    }

    @Published private(set) var entries: [Provider: Entry] = [:]
    @Published private(set) var now = Date()
    /// Providers the user connected — the only ones read and shown in the menu bar.
    @Published private(set) var activeProviders: [Provider] = []
    /// Providers whose web login window is open right now.
    @Published private(set) var loggingIn: Set<Provider> = []

    /// A request that hasn't answered after this long is abandoned (its late answer is ignored).
    static let requestTimeout: TimeInterval = 45

    let settings: AppSettings
    private let backend: UsageBackend
    private let clock: () -> Date
    private let schedule: Scheduler
    private var refreshTimer: Timer?
    private var clockTimer: Timer?
    private var retryCancel: [Provider: () -> Void] = [:]
    private var bag = Set<AnyCancellable>()

    init(settings: AppSettings, backend: UsageBackend? = nil,
         clock: @escaping () -> Date = Date.init, schedule: @escaping Scheduler = Schedulers.live) {
        self.settings = settings
        self.backend = backend ?? LiveBackend()
        self.clock = clock
        self.schedule = schedule
        updateActive()
    }

    func start() {
        refreshAll()
        scheduleRefresh()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = self?.clock() ?? Date() }
        }
        settings.$refreshMinutes.dropFirst().removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.scheduleRefresh() } }
            .store(in: &bag)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.refreshAll() }
            }
            .store(in: &bag)
    }

    private func scheduleRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(AppSettings.validRefreshMinutes(settings.refreshMinutes)) * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
    }

    func refreshAll(manual: Bool = false) {
        now = clock()
        updateActive()
        activeProviders.forEach { refresh($0, manual: manual) }
    }

    /// Refresh when the popover opens, but not more than once a minute.
    func refreshIfStale() {
        updateActive()
        let stale = activeProviders.contains { p in
            guard let s = entries[p]?.snapshot else { return true }
            return clock().timeIntervalSince(s.fetchedAt) > 60
        }
        if stale { refreshAll() } else { now = clock() }
    }

    private func updateActive() {
        let active = Provider.allCases.filter(settings.isConnected)
        if active != activeProviders { activeProviders = active }
    }

    // MARK: - Connecting

    /// Opens the in-app login window for claude.ai / chatgpt.com.
    /// Waits for any earlier disconnect to finish erasing its login data, so the new login's
    /// cookies can't be deleted by the old logout. A result from a window that was closed or
    /// superseded (e.g. by a disconnect) is ignored.
    func logInOnWeb(_ p: Provider) {
        guard !loggingIn.contains(p) else { return }
        loggingIn.insert(p)
        loginAttempt[p, default: 0] += 1
        let attempt = loginAttempt[p]!
        let erasing = forgetting[p]?.task
        Task { [weak self] in
            await erasing?.value
            guard let self, self.loginAttempt[p] == attempt, self.loggingIn.contains(p) else { return }
            self.backend.presentLogin(p) { [weak self] success in
                guard let self, self.loginAttempt[p] == attempt, self.loggingIn.contains(p) else { return }
                self.loggingIn.remove(p)
                guard success else { return }
                self.setConnection(p, .web)
                self.refresh(p, manual: true)
            }
        }
    }

    /// Reuses the Claude Code / Codex CLI login on this Mac. If there is none, opens Terminal to log in.
    func useCLI(_ p: Provider) {
        if !backend.isCLISetUp(p) { backend.openTerminalLogin(p) }
        setConnection(p, .cli)
        refresh(p, manual: true)
    }

    /// Runs the CLI in Terminal so it refreshes its own login; we pick up the new token automatically.
    func refreshCLIInTerminal(_ p: Provider) {
        backend.openTerminalLogin(p)
        scheduleRetry(p, at: clock().addingTimeInterval(20))
    }

    /// One flow: cancel the request and retries, close the login window, ignore its late result,
    /// clear the card, then erase what the app holds for this connection (never the CLI's own login).
    func disconnect(_ p: Provider) {
        let old = settings.connection(p)
        if loggingIn.remove(p) != nil { backend.dismissLogin(p) }
        loginAttempt[p, default: 0] += 1
        setConnection(p, .none)
        guard old != .none else { return }
        let previous = forgetting[p]?.task
        let clearShared = old == .web && !Provider.allCases.contains { settings.connection($0) == .web }
        let token = UUID()
        let task = Task { [weak self, backend] in
            await previous?.value
            await backend.forgetAppData(p, connection: old, clearSharedSignIn: clearShared)
            if self?.forgetting[p]?.token == token { self?.forgetting[p] = nil }
        }
        forgetting[p] = (token, task)
    }

    /// Changing how a provider is connected starts a new "generation": anything still running
    /// for the previous one is cancelled and its results are ignored.
    private func setConnection(_ p: Provider, _ c: Connection) {
        if settings.connection(p) != c {
            generation[p, default: 0] += 1
            abandonRequest(p)
            cancelRetry(p)
            entries[p] = nil
        }
        settings.connections[p] = c
        updateActive()
    }

    // MARK: - Fetching

    private struct InFlight {
        let id: Int
        let generation: Int
        let interactive: Bool
        let task: Task<Void, Never>
        let cancelTimeout: () -> Void
    }
    private var inflight: [Provider: InFlight] = [:]
    private var generation: [Provider: Int] = [:]
    private var nextRequestID = 0
    /// Earliest time the server allows the next request (after a 429). Kept across reconnects.
    private var nextAllowed: [Provider: Date] = [:]
    private var retryDue: [Provider: Date] = [:]
    private var loginAttempt: [Provider: Int] = [:]
    private var forgetting: [Provider: (token: UUID, task: Task<Void, Never>)] = [:]

    /// Every trigger (timer, button, menu, wake, reconnect) goes through here.
    func refresh(_ p: Provider, manual: Bool = false) {
        let connection = settings.connection(p)
        guard connection != .none else { return }
        if let until = nextAllowed[p], clock() < until {
            scheduleRetry(p, at: until)          // the one retry at the allowed time stays booked
            return
        }
        if let current = inflight[p] {
            // Join the running request. Only a button press that must show the Keychain prompt replaces it.
            let needsPrompt = manual && !current.interactive && entries[p]?.error?.needsApproval == true
            guard needsPrompt else { return }
            abandonRequest(p)
        }
        nextRequestID += 1
        let id = nextRequestID
        cancelRetry(p)
        entries[p, default: Entry()].loading = true
        let task = Task { [weak self, backend] in
            let result: Result<ProviderSnapshot, Error>
            do { result = .success(try await backend.fetch(p, via: connection, interactive: manual)) }
            catch { result = .failure(error) }
            self?.finish(p, id: id, result)
        }
        let cancelTimeout = schedule(Self.requestTimeout) { [weak self] in self?.timeOut(p, id: id) }
        inflight[p] = InFlight(id: id, generation: generation[p, default: 0], interactive: manual,
                               task: task, cancelTimeout: cancelTimeout)
    }

    private func finish(_ p: Provider, id: Int, _ result: Result<ProviderSnapshot, Error>) {
        // Ignore answers from a superseded request or an earlier connection, success or failure.
        guard let current = inflight[p], current.id == id, current.generation == generation[p, default: 0] else { return }
        current.cancelTimeout()
        inflight[p] = nil
        now = clock()
        switch result {
        case .success(let snap):
            nextAllowed[p] = nil
            entries[p] = Entry(snapshot: snap)
        case .failure(let error):
            fail(p, ProviderError.wrap(error))
        }
    }

    private func timeOut(_ p: Provider, id: Int) {
        guard let current = inflight[p], current.id == id else { return }
        abandonRequest(p)
        fail(p, ProviderError.timedOut)
    }

    private func fail(_ p: Provider, _ e: ProviderError) {
        var e = e
        if e.kind == .rateLimited {
            let until = e.retryAt ?? clock().addingTimeInterval(RetryPolicy.defaultWait)
            e = ProviderError.rateLimited(until: until)
            nextAllowed[p] = until
            scheduleRetry(p, at: until)
        } else if e.kind == .network || e.kind == .server {
            scheduleRetry(p, at: clock().addingTimeInterval(RetryPolicy.transientRetry))
        }
        entries[p] = Entry(snapshot: entries[p]?.snapshot, error: e, loading: false)
        NSLog("AIUsage: \(p.rawValue) refresh failed (\(e.kind))")
    }

    private func abandonRequest(_ p: Provider) {
        guard let current = inflight[p] else { return }
        current.task.cancel()
        current.cancelTimeout()
        inflight[p] = nil
        entries[p]?.loading = false
    }

    private func scheduleRetry(_ p: Provider, at due: Date) {
        if retryDue[p] == due, retryCancel[p] != nil { return }
        cancelRetry(p)
        retryDue[p] = due
        retryCancel[p] = schedule(max(0, due.timeIntervalSince(clock()))) { [weak self] in
            self?.retryCancel[p] = nil
            self?.retryDue[p] = nil
            self?.refresh(p)
        }
    }

    private func cancelRetry(_ p: Provider) {
        retryCancel[p]?()
        retryCancel[p] = nil
        retryDue[p] = nil
    }

    /// Test hook: pretend a provider is connected with this snapshot.
    func testInject(_ p: Provider, _ snap: ProviderSnapshot) {
        entries[p] = Entry(snapshot: snap)
        if !activeProviders.contains(p) { activeProviders = Provider.allCases.filter { $0 == p || activeProviders.contains($0) } }
    }
}
