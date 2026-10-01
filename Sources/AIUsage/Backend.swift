import AppKit

/// Everything the store needs from the outside world. The app uses `LiveBackend`;
/// tests substitute a fake to control servers, login windows and timing.
@MainActor
protocol UsageBackend: AnyObject {
    /// Reads current usage for `p` through `connection`. Must honour task cancellation where it can.
    func fetch(_ p: Provider, via connection: Connection, interactive: Bool) async throws -> ProviderSnapshot
    /// Shows the web login for `p`; `done(true)` once logged in, `done(false)` if closed.
    func presentLogin(_ p: Provider, done: @escaping @MainActor (Bool) -> Void)
    /// Closes an open login window for `p` (and its popups) without calling `done`.
    func dismissLogin(_ p: Provider)
    /// Drops what the app itself holds for `p`: the web login data for `.web`, cached tokens for `.cli`.
    /// Never touches the CLI's own login files or Keychain item.
    /// `clearSharedSignIn`: also erase Google/Apple/Microsoft sign-in data, which both services share —
    /// only when no service is connected through the web any more.
    func forgetAppData(_ p: Provider, connection: Connection, clearSharedSignIn: Bool) async
    func openTerminalLogin(_ p: Provider)
    /// Whether the CLI for `p` has a login on this Mac (no prompts, no secrets read).
    func isCLISetUp(_ p: Provider) -> Bool
}

@MainActor
final class LiveBackend: UsageBackend {
    private let claude = ClaudeProvider()
    private let codex = CodexProvider()
    private lazy var web: [Provider: WebAccount] = Dictionary(uniqueKeysWithValues: Provider.allCases.map { ($0, WebAccount(provider: $0)) })

    func fetch(_ p: Provider, via connection: Connection, interactive: Bool) async throws -> ProviderSnapshot {
        switch (connection, p) {
        case (.web, _): return try await web[p]!.fetch()
        case (.cli, .claude): return try await claude.fetch(interactive: interactive)
        case (.cli, .codex): return try await codex.fetch()
        case (.none, _): throw CancellationError()
        }
    }

    func presentLogin(_ p: Provider, done: @escaping @MainActor (Bool) -> Void) {
        guard let account = web[p] else { return }
        LoginWindow.show(for: account, completion: done)
    }

    func dismissLogin(_ p: Provider) { LoginWindow.dismiss(p) }

    func forgetAppData(_ p: Provider, connection: Connection, clearSharedSignIn: Bool) async {
        switch connection {
        case .web: await web[p]?.logOut(clearSharedSignIn: clearSharedSignIn)
        case .cli: if p == .claude { claude.resetCache() }
        case .none: break
        }
    }

    func openTerminalLogin(_ p: Provider) { p.openLoginInTerminal() }
    func isCLISetUp(_ p: Provider) -> Bool { p.isSetUp }
}

/// Runs `action` after `delay` seconds on the main actor; returns a cancel function.
typealias Scheduler = @MainActor (_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> (() -> Void)

enum Schedulers {
    static let live: Scheduler = { delay, action in
        let work = DispatchWorkItem { MainActor.assumeIsolated { action() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: work)
        return { work.cancel() }
    }
}
