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

    private let d = UserDefaults.standard

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
    @Published var refreshMinutes: Int { didSet { d.set(refreshMinutes, forKey: "refreshMinutes") } }
    @Published var onboarded: Bool { didSet { d.set(onboarded, forKey: "onboarded") } }

    init() {
        let d = UserDefaults.standard
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
        refreshMinutes = max(1, d.integer(forKey: "refreshMinutes"))
        onboarded = d.bool(forKey: "onboarded") || d.bool(forKey: "connectedClaude") || d.bool(forKey: "connectedCodex")
    }

    func barMode(_ p: Provider) -> BarMode { barModes[p] ?? .weekly }
    func connection(_ p: Provider) -> Connection { connections[p] ?? .none }
    func isConnected(_ p: Provider) -> Bool { connection(p) != .none }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("AIUsage: launch at login change failed: \(error)")
            }
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

    let settings: AppSettings
    private let claude = ClaudeProvider()
    private let codex = CodexProvider()
    private lazy var web: [Provider: WebAccount] = Dictionary(uniqueKeysWithValues: Provider.allCases.map { ($0, WebAccount(provider: $0)) })
    private var refreshTimer: Timer?
    private var clockTimer: Timer?
    private var retryWork: [Provider: DispatchWorkItem] = [:]
    private var bag = Set<AnyCancellable>()

    init(settings: AppSettings) {
        self.settings = settings
        updateActive()
    }

    func start() {
        refreshAll()
        scheduleRefresh()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
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
        refreshTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(settings.refreshMinutes * 60), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
    }

    func refreshAll(manual: Bool = false) {
        now = Date()
        updateActive()
        activeProviders.forEach { refresh($0, manual: manual) }
    }

    /// Refresh when the popover opens, but not more than once a minute.
    func refreshIfStale() {
        updateActive()
        let stale = activeProviders.contains { p in
            guard let s = entries[p]?.snapshot else { return true }
            return Date().timeIntervalSince(s.fetchedAt) > 60
        }
        if stale { refreshAll() } else { now = Date() }
    }

    private func updateActive() {
        let active = Provider.allCases.filter(settings.isConnected)
        if active != activeProviders { activeProviders = active }
    }

    // MARK: - Connecting

    /// Opens the in-app login window for claude.ai / chatgpt.com.
    func logInOnWeb(_ p: Provider) {
        guard let account = web[p] else { return }
        loggingIn.insert(p)
        LoginWindow.show(for: account) { [weak self] success in
            guard let self else { return }
            self.loggingIn.remove(p)
            guard success else { return }
            self.setConnection(p, .web)
            self.refresh(p, manual: true)
        }
    }

    /// Reuses the Claude Code / Codex CLI login on this Mac. If there is none, opens Terminal to log in.
    func useCLI(_ p: Provider) {
        if !p.isSetUp { p.openLoginInTerminal() }
        setConnection(p, .cli)
        refresh(p, manual: true)
    }

    /// Runs the CLI in Terminal so it refreshes its own login; we pick up the new token automatically.
    func refreshCLIInTerminal(_ p: Provider) {
        p.openLoginInTerminal()
        scheduleRetry(p, after: 20)
    }

    func disconnect(_ p: Provider) {
        let wasWeb = settings.connection(p) == .web
        setConnection(p, .none)
        if wasWeb, let account = web[p] { Task { await account.logOut() } }
    }

    private func setConnection(_ p: Provider, _ c: Connection) {
        retryWork[p]?.cancel()
        if settings.connection(p) != c { entries[p] = nil }
        settings.connections[p] = c
        updateActive()
    }

    // MARK: - Fetching

    func refresh(_ p: Provider, manual: Bool = false) {
        if entries[p]?.loading == true && !manual { return }
        let connection = settings.connection(p)
        guard connection != .none else { return }
        entries[p, default: Entry()].loading = true
        retryWork[p]?.cancel()
        Task {
            do {
                let snap: ProviderSnapshot
                switch (connection, p) {
                case (.web, _): snap = try await web[p]!.fetch()
                case (.cli, .claude): snap = try await claude.fetch(interactive: manual)
                default: snap = try await codex.fetch()
                }
                guard settings.connection(p) == connection else { return }
                entries[p] = Entry(snapshot: snap)
            } catch {
                guard settings.connection(p) == connection else { return }
                let e = ProviderError.wrap(error)
                entries[p] = Entry(snapshot: entries[p]?.snapshot, error: e, loading: false)
                NSLog("AIUsage: \(p.rawValue) refresh failed: \(e.message)")
                switch e.kind {
                case .network: scheduleRetry(p, after: 60)
                case .rateLimited: scheduleRetry(p, after: 300)
                default: break
                }
            }
            now = Date()
        }
    }

    private func scheduleRetry(_ p: Provider, after seconds: TimeInterval) {
        retryWork[p]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh(p) }
        retryWork[p] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Test hook: pretend a provider is connected with this snapshot.
    func testInject(_ p: Provider, _ snap: ProviderSnapshot) {
        entries[p] = Entry(snapshot: snap)
        if !activeProviders.contains(p) { activeProviders = Provider.allCases.filter { $0 == p || activeProviders.contains($0) } }
    }
}
