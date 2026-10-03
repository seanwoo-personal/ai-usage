import SwiftUI

/// Lets views open app-level windows without holding the AppDelegate.
enum AppActions {
    @MainActor static var showOnboarding: () -> Void = {}
}

struct PopoverView: View {
    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var settings: AppSettings
    @State private var showSettings = false

    private var unconnected: [Provider] { Provider.allCases.filter { !settings.isConnected($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            UpdateBanner()

            if store.activeProviders.isEmpty {
                WelcomeBlock()
            }
            ForEach(store.activeProviders) { p in
                ProviderCard(provider: p, entry: store.entries[p], now: store.now, showRemaining: settings.showRemaining)
            }
            if !unconnected.isEmpty {
                if !store.activeProviders.isEmpty {
                    Text(L.t("다른 서비스도 연결할 수 있어요", "You can also connect"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if store.activeProviders.isEmpty { TrustBlock(compact: true) }
                ForEach(unconnected) { p in ConnectPanel(provider: p, compact: true) }
            }

            if showSettings {
                Divider()
                SettingsSection()
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 360)
    }

    private var header: some View {
        HStack {
            Text("AI Usage").font(.headline)
            Spacer()
            if store.entries.values.contains(where: \.loading) {
                ProgressView().controlSize(.small)
            }
            if !store.activeProviders.isEmpty {
                Button {
                    store.refreshAll(manual: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(L.t("지금 새로고침 (⌘R)", "Refresh now (⌘R)"))
                .keyboardShortcut("r")
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button(showSettings ? L.t("설정 닫기", "Hide Settings") : L.t("설정", "Settings")) {
                withAnimation(.easeInOut(duration: 0.15)) { showSettings.toggle() }
            }
            Button(L.t("사용 안내", "Guide")) { AppActions.showOnboarding() }
            Spacer()
            Button(L.t("종료", "Quit")) { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }
}

/// Shown while nothing is connected: what the app does and why it's safe.
struct WelcomeBlock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.t("Claude와 Codex의 남은 사용량과 리셋 시간을 메뉴 막대에서 바로 보여드려요.",
                     "See how much Claude and Codex usage you have left, and when it resets, right in the menu bar."))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ProviderLogo: View {
    let provider: Provider
    var size: CGFloat = 14

    var body: some View {
        if let img = Logos.image(for: provider) {
            Image(nsImage: img).renderingMode(.template).resizable().frame(width: size, height: size)
        } else {
            Text(String(provider.displayName.prefix(1))).font(.system(size: size * 0.8, weight: .bold))
        }
    }
}

struct ProviderCard: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var store: UsageStore
    let provider: Provider
    let entry: UsageStore.Entry?
    let now: Date
    let showRemaining: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ProviderLogo(provider: provider)
                Text(provider.displayName).font(.system(size: 13, weight: .semibold))
                if let plan = entry?.snapshot?.plan {
                    Text(plan)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
                Spacer()
                sourceLabel
            }

            if let snap = entry?.snapshot {
                ForEach(snap.windows) { w in
                    WindowRow(window: w.effective(at: now), now: now, showRemaining: showRemaining)
                }
                .opacity(entry?.error != nil ? 0.6 : 1)
                if snap.window({ $0 == .session }) != nil && snap.window({ $0 == .weekly }) != nil {
                    HStack {
                        Text(L.t("메뉴 막대에", "Menu bar")).font(.caption).foregroundStyle(.secondary)
                        Picker("", selection: Binding(
                            get: { settings.barMode(provider) },
                            set: { settings.barModes[provider] = $0 })) {
                            ForEach(AppSettings.BarMode.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }
            } else if entry?.error == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L.t("사용량을 불러오고 있어요…", "Loading your usage…")).font(.callout).foregroundStyle(.secondary)
                }
            }

            if let err = entry?.error {
                ErrorBanner(provider: provider, error: err, hasOldValues: entry?.snapshot != nil,
                            oldAge: entry?.snapshot.map { L.ago($0.fetchedAt, now: now) })
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    @ViewBuilder private var sourceLabel: some View {
        if let snap = entry?.snapshot {
            switch snap.source {
            case .web:
                Text(L.t("웹 로그인 · \(L.ago(snap.fetchedAt, now: now))", "Web · \(L.ago(snap.fetchedAt, now: now))"))
                    .font(.caption2).foregroundStyle(.secondary)
            case .live:
                Text("\(provider.cliName) · \(L.ago(snap.fetchedAt, now: now))")
                    .font(.caption2).foregroundStyle(.secondary)
            case .log(let at):
                Text(L.t("마지막 사용 기준 · \(L.ago(at, now: now))", "From last use · \(L.ago(at, now: now))"))
                    .font(.caption2).foregroundStyle(.secondary)
                    .help(L.t("실시간 조회에 실패해 Codex 기록에 남은 마지막 값을 보여주고 있어요.",
                              "Live lookup failed; showing the last value Codex recorded."))
            }
        }
    }
}

/// What happened, and one clear next step.
struct ErrorBanner: View {
    @EnvironmentObject var store: UsageStore
    let provider: Provider
    let error: ProviderError
    let hasOldValues: Bool
    let oldAge: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(error.message).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: icon)
            }
            .font(.caption)
            .foregroundStyle(tint)

            if hasOldValues, let oldAge {
                Text(L.t("위 수치는 \(oldAge)에 받은 값이에요.", "The numbers above are from \(oldAge)."))
                    .font(.caption2).foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                switch error.kind {
                case .needsLogin:
                    primary(L.t("다시 로그인", "Log in again")) { store.logInOnWeb(provider) }
                case .cliExpired:
                    primary(L.t("웹으로 로그인 (추천)", "Log in on the web (recommended)")) { store.logInOnWeb(provider) }
                    secondary(L.t("터미널에서 갱신", "Refresh in Terminal")) { store.refreshCLIInTerminal(provider) }
                case .cliMissing:
                    primary(L.t("웹으로 로그인", "Log in on the web")) { store.logInOnWeb(provider) }
                    secondary(L.t("터미널에서 로그인", "Log in in Terminal")) { store.refreshCLIInTerminal(provider) }
                case .needsApproval:
                    primary(L.t("허용하기", "Allow access")) { store.refresh(provider, manual: true) }
                    secondary(L.t("웹으로 로그인", "Log in on the web")) { store.logInOnWeb(provider) }
                case .noLimits:
                    secondary(L.t("다른 계정으로 로그인", "Use another account")) { store.logInOnWeb(provider) }
                case .rateLimited:
                    EmptyView()   // waits for the server's allowed time automatically
                case .network, .server, .generic:
                    secondary(L.t("다시 시도", "Try again")) { store.refresh(provider, manual: true) }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.1)))
    }

    private var icon: String {
        switch error.kind {
        case .network: return "wifi.exclamationmark"
        case .server: return "exclamationmark.icloud"
        case .rateLimited: return "hourglass"
        case .needsLogin, .cliExpired, .cliMissing: return "person.crop.circle.badge.exclamationmark"
        case .needsApproval: return "lock"
        case .noLimits: return "info.circle"
        case .generic: return "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch error.kind {
        case .network, .server, .rateLimited, .noLimits: return .secondary
        default: return .orange
        }
    }

    private func primary(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.borderedProminent).controlSize(.small)
    }

    private func secondary(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action).controlSize(.small)
    }
}

struct WindowRow: View {
    let window: UsageWindow
    let now: Date
    let showRemaining: Bool

    private var remaining: Double { window.remainingPercent }
    private var tint: Color { remaining > 50 ? .green : remaining > 20 ? .orange : .red }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.kind.title).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(window.percentText(showRemaining: showRemaining))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(showRemaining ? L.t("남음", "left") : L.t("사용", "used"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(tint)
                        .frame(width: geo.size.width * window.barFraction(showRemaining: showRemaining))
                    // Even-pace marker: where you'd be if usage were spread evenly across the window.
                    if let elapsed = window.elapsedFraction(at: now) {
                        let pace = showRemaining ? 1 - elapsed : elapsed
                        Rectangle().fill(Color.primary.opacity(0.55))
                            .frame(width: 1.5, height: 10)
                            .offset(x: max(0, geo.size.width * pace - 0.75))
                    }
                }
            }
            .frame(height: 6)
            .help(L.t("세로 눈금 = 균등하게 썼을 때의 기준선", "Tick = even-pace line across the window"))

            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.2.circlepath").imageScale(.small)
                if let r = window.resetsAt {
                    Text(L.t("리셋 \(L.resetDate(r))", "Resets \(L.resetDate(r))"))
                    Spacer()
                    Text(L.countdown(r.timeIntervalSince(now))).monospacedDigit()
                } else {
                    Text(window.didReset ? L.t("리셋됨 · 새로고침 대기", "Reset · waiting for refresh")
                                         : L.t("리셋 시각 정보 없음", "Reset time unknown"))
                    Spacer()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

struct SettingsSection: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Provider.allCases.filter(settings.isConnected)) { p in
                HStack {
                    ProviderLogo(provider: p, size: 12)
                    Text(settings.connection(p) == .web
                         ? L.t("\(p.displayName) — 웹 로그인으로 연결됨", "\(p.displayName) — connected via web login")
                         : L.t("\(p.displayName) — \(p.cliName) 로그인 사용 중", "\(p.displayName) — using \(p.cliName) login"))
                    Spacer()
                    Button(L.t("연결 해제", "Disconnect")) { store.disconnect(p) }.controlSize(.small)
                }
            }

            Picker(L.t("퍼센트", "Percent"), selection: $settings.showRemaining) {
                Text(L.t("남은 양", "Remaining")).tag(true)
                Text(L.t("사용한 양", "Used")).tag(false)
            }
            .pickerStyle(.segmented)

            Picker(L.t("새로고침", "Refresh"), selection: $settings.refreshMinutes) {
                ForEach(AppSettings.refreshChoices, id: \.self) { Text(L.t("\($0)분마다", "Every \($0) min")).tag($0) }
            }

            Toggle(L.t("메뉴 막대에 리셋까지 남은 시간 표시", "Show time to reset in menu bar"), isOn: $settings.showResetInBar)
            Toggle(L.t("Mac에 로그인하면 자동으로 실행", "Open at login"), isOn: Binding(
                get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
            if let message = settings.loginItemMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SystemSettings()

            UpdateSettings()

            Text("AI Usage \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · " + L.t("만든 사람: Sean", "Made by Sean"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .font(.callout)
        .toggleStyle(.checkbox)
    }
}

/// Shown at the top of the popover when a newer version is out (or an update is running).
struct UpdateBanner: View {
    @EnvironmentObject var updater: Updater

    var body: some View {
        if let release = updater.available {
            VStack(alignment: .leading, spacing: 6) {
                // One row: what's new on the left, actions on the right.
                HStack(spacing: 8) {
                    Label(L.t("새 버전 \(release.version)이 나왔어요", "Version \(release.version) is available"),
                          systemImage: "arrow.down.circle")
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if updater.installing {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(L.t("바뀐 점", "What's new")) { NSWorkspace.shared.open(release.page) }
                            .buttonStyle(.link).font(.caption)
                        Button(L.t("업데이트", "Update")) { updater.install() }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                            .disabled(!updater.canInstall)
                    }
                }
                if updater.installing {
                    Text(L.t("확인하고 설치하는 중이에요. 끝나면 앱이 다시 열려요.", "Checking and installing. The app reopens when done."))
                        .font(.caption).foregroundStyle(.secondary)
                } else if !updater.canInstall {
                    Text(L.t("응용 프로그램 폴더에 설치된 앱에서 업데이트할 수 있어요.", "Updates run from the app in your Applications folder."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let problem = updater.problem {
                    Text(problem).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.1)))
        }
    }
}

/// "Check for updates automatically" + manual check, in Settings.
struct UpdateSettings: View {
    @EnvironmentObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(L.t("새 버전 자동으로 확인 (하루 한 번)", "Check for new versions automatically (daily)"), isOn: Binding(
                get: { updater.autoCheck }, set: { updater.autoCheck = $0 }))
            HStack(spacing: 8) {
                Button(L.t("지금 확인", "Check now")) { Task { await updater.check() } }
                    .controlSize(.small).disabled(updater.checking)
                if updater.checking {
                    ProgressView().controlSize(.small)
                } else if updater.available == nil, let last = updater.lastChecked {
                    Text(L.t("최신 버전이에요 · \(L.ago(last)) 확인", "Up to date · checked \(L.ago(last))"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if updater.available == nil, let problem = updater.problem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

/// Optional CPU · RAM · SSD · network section in the menu bar.
struct SystemSettings: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(L.t("메뉴 막대에 시스템 상태 표시", "Show system status in the menu bar"), isOn: $settings.showSystem)
            if settings.showSystem {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: 4) {
                    ForEach(SystemStatusImage.Metric.allCases) { m in
                        Toggle(m.label, isOn: Binding(
                            get: { settings.systemMetrics.contains(m) },
                            set: { on in if on { settings.systemMetrics.insert(m) } else { settings.systemMetrics.remove(m) } }))
                    }
                }
                .padding(.leading, 18)
                Toggle(L.t("상태가 나쁘면 노랑·빨강으로 표시", "Turn yellow or red when the Mac is under strain"), isOn: $settings.systemColors)
                    .padding(.leading, 18)
                    .help(L.t("CPU: 최근 5초 평균 70% 이상 노랑, 90% 이상 빨강 · RAM: 여유 메모리 20% 미만 노랑, 10% 미만 빨강 · SSD: 90% 이상 노랑, 95% 이상 빨강",
                              "CPU: 5-second average ≥70% yellow, ≥90% red · RAM: under 20% free yellow, under 10% red · SSD: ≥90% yellow, ≥95% red"))
                Text(L.t("1초마다 이 Mac의 CPU·메모리·디스크·네트워크 사용량을 읽어요. 어디로도 보내지 않아요.",
                         "Reads this Mac's CPU, memory, disk and network every second. Nothing is sent anywhere."))
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 18)
            }
            Toggle(L.t("다른 AI·도구가 이 Mac 상태를 읽을 수 있게 저장", "Save this Mac's status for other AI tools"), isOn: $settings.shareStatus)
                .help(L.t("5초마다 이 Mac 안의 파일에만 저장해요. 다른 Mac이나 AI는 SSH로 들어와 `AIUsage mcp`로 읽어 가요. 토큰·계정 정보는 넣지 않아요.",
                          "Saved every 5 seconds to a file on this Mac only. Other Macs or AIs read it over SSH with `AIUsage mcp`. No tokens or account details."))
        }
    }
}
