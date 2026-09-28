import AppKit
import SwiftUI

/// First-run guide: what the app does → connect services → where to look.
/// Also reachable later from the popover ("Guide").
@MainActor
final class OnboardingWindow: NSObject, NSWindowDelegate {
    private static var current: OnboardingWindow?
    private let window: NSWindow

    static func show(store: UsageStore, settings: AppSettings) {
        if let c = current {
            c.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let ow = OnboardingWindow(store: store, settings: settings)
        current = ow
        ow.window.center()
        ow.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(store: UsageStore, settings: AppSettings) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = L.t("AI Usage 시작하기", "Welcome to AI Usage")
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.level = .floating   // an app without a Dock icon can't always pull its windows to the front
        window.delegate = self
        let view = OnboardingView(close: { [weak self] in self?.window.close() })
            .environmentObject(store)
            .environmentObject(settings)
        window.contentView = NSHostingView(rootView: view)
    }

    func windowWillClose(_ notification: Notification) {
        Self.current = nil
    }
}

struct OnboardingView: View {
    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var settings: AppSettings
    let close: () -> Void
    @State private var step = 0
    @State private var openAtLogin = true

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: intro
                case 1: connect
                default: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 36)
            .padding(.top, 44)

            HStack {
                StepDots(current: step, total: 3)
                Spacer()
                if step == 1 && store.activeProviders.isEmpty {
                    Button(L.t("나중에 할게요", "Skip for now")) { step = 2 }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 6)
                }
                if step > 0 {
                    Button(L.t("이전", "Back")) { step -= 1 }
                }
                Button(primaryTitle) { next() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(step == 1 && store.activeProviders.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 560, height: 720)
    }

    private var primaryTitle: String {
        switch step {
        case 0: return L.t("시작하기", "Get started")
        case 1: return L.t("다음", "Next")
        default: return L.t("완료", "Done")
        }
    }

    private func next() {
        if step < 2 { step += 1; return }
        if openAtLogin != settings.launchAtLogin { settings.launchAtLogin = openAtLogin }
        settings.onboarded = true
        close()
    }

    // MARK: Step 1 — what it is, and why it's safe

    private var intro: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L.t("AI 사용량을 한눈에", "Your AI usage at a glance"))
                    .font(.system(size: 26, weight: .bold))
                Text(L.t("Claude와 Codex를 얼마나 더 쓸 수 있는지, 언제 다시 채워지는지 메뉴 막대에서 바로 보여드려요.",
                         "See how much Claude and Codex you have left, and when it refills — right in your menu bar."))
                    .font(.title3).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            MenuBarPreview(blocks: [
                .init(provider: .claude, top: "5d 21h", bottom: "76%"),
                .init(provider: .codex, top: "6d 1h", bottom: "75%"),
            ])

            VStack(alignment: .leading, spacing: 14) {
                Feature(icon: "gauge.with.dots.needle.67percent",
                        title: L.t("남은 사용량", "What's left"),
                        text: L.t("5시간 세션 한도와 주간(7일) 한도를 퍼센트로 보여줘요.", "5-hour session and weekly limits, as a percentage."))
                Feature(icon: "clock.arrow.circlepath",
                        title: L.t("리셋까지 남은 시간", "Time until reset"),
                        text: L.t("한도가 언제 다시 채워지는지 알려줘요.", "When each limit refills."))
                Feature(icon: "lock.shield",
                        title: L.t("안전하게", "Private by design"),
                        text: L.t("로그인 정보는 이 Mac에만 저장돼요. 앱은 claude.ai·chatgpt.com 공식 서버와만 통신하고, 개발자를 포함해 누구에게도 정보를 보내지 않아요.",
                                  "Your login stays on this Mac. The app only talks to claude.ai and chatgpt.com and sends nothing to anyone else — including its developer."))
            }
        }
    }

    // MARK: Step 2 — connect

    private var connect: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L.t("쓰고 있는 서비스를 연결하세요", "Connect the services you use"))
                        .font(.system(size: 24, weight: .bold))
                    Text(L.t("서비스마다 편한 방법을 고르면 돼요. 하나만 연결해도 되고, 나중에 메뉴 막대에서 연결해도 돼요.",
                             "Pick whichever way is easier for each service. One is enough, and you can do this later from the menu bar."))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                TrustBlock()
                ForEach(Provider.allCases) { p in
                    OnboardingConnectCard(provider: p)
                }
            }
            .padding(.bottom, 8)
        }
    }

    // MARK: Step 3 — where to look

    private var done: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(store.activeProviders.isEmpty ? L.t("거의 다 됐어요", "Almost there") : L.t("준비 완료!", "You're all set!"))
                    .font(.system(size: 26, weight: .bold))
                Text(store.activeProviders.isEmpty
                     ? L.t("화면 오른쪽 위 메뉴 막대의 게이지 아이콘을 누르면 언제든 연결할 수 있어요.",
                           "Click the gauge icon at the top right of your screen any time to connect.")
                     : L.t("이제 화면 오른쪽 위 메뉴 막대에 이렇게 보여요.", "Look at the top right of your screen — it now shows:"))
                    .font(.title3).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !store.activeProviders.isEmpty {
                MenuBarPreview(blocks: StatusImage.blocks(store: store, settings: settings))
                VStack(alignment: .leading, spacing: 12) {
                    Feature(icon: "arrow.up", title: L.t("윗줄", "Top line"),
                            text: L.t("한도가 다시 채워지기까지 남은 시간 (예: 5d 21h = 5일 21시간)", "Time until the limit refills (e.g. 5d 21h)"))
                    Feature(icon: "arrow.down", title: L.t("아랫줄", "Bottom line"),
                            text: L.t("남은 사용량. 0%가 되면 리셋될 때까지 쓸 수 없어요.", "What's left. At 0% you wait for the reset."))
                    Feature(icon: "cursorarrow.click", title: L.t("클릭하면", "Click it"),
                            text: L.t("한도별 자세한 정보와 설정을 볼 수 있어요.", "for details per limit and settings."))
                }
            }

            Toggle(L.t("Mac에 로그인하면 자동으로 실행", "Open automatically when I log in"), isOn: $openAtLogin)
                .toggleStyle(.checkbox)
            Spacer()
        }
    }
}

private struct OnboardingConnectCard: View {
    @EnvironmentObject var store: UsageStore
    @EnvironmentObject var settings: AppSettings
    let provider: Provider

    var body: some View {
        if settings.isConnected(provider) {
            connectedCard
        } else {
            ConnectPanel(provider: provider)
        }
    }

    private var connectedCard: some View {
        let entry = store.entries[provider]
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ProviderLogo(provider: provider, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName).font(.headline)
                    Text(settings.connection(provider) == .web
                         ? L.t("\(provider.website) 로그인으로 연결", "Connected via \(provider.website)")
                         : L.t("\(provider.cliName) 로그인으로 연결", "Connected via \(provider.cliName)"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if entry?.snapshot != nil {
                    Label(L.t("연결됨", "Connected"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.callout.weight(.medium))
                } else if entry?.error == nil {
                    ProgressView().controlSize(.small)
                }
            }
            if let snap = entry?.snapshot, let w = snap.window({ $0 == .weekly }) ?? snap.windows.first {
                Text(L.t("지금 \(w.kind.title) 한도가 \(Int(w.remainingPercent.rounded()))% 남았어요.",
                         "\(Int(w.remainingPercent.rounded()))% of your \(w.kind.title) limit is left."))
                    .font(.caption).foregroundStyle(.secondary)
            } else if let err = entry?.error {
                ErrorBanner(provider: provider, error: err, hasOldValues: false, oldAge: nil)
                Button(L.t("다른 방법으로 연결하기", "Connect another way")) { store.disconnect(provider) }
                    .buttonStyle(.link).font(.caption)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
    }
}

/// A strip that looks like the menu bar, drawing the real status image.
struct MenuBarPreview: View {
    let blocks: [StatusImage.Block]

    var body: some View {
        HStack {
            Spacer()
            Image(nsImage: StatusImage.render(blocks))
                .renderingMode(.template)
                .foregroundStyle(.white)
            Image(systemName: "wifi").foregroundStyle(.white.opacity(0.8))
            Text(Date.now, format: .dateTime.hour().minute())
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8).fill(LinearGradient(
            colors: [Color(red: 0.16, green: 0.2, blue: 0.3), Color(red: 0.1, green: 0.12, blue: 0.2)],
            startPoint: .leading, endPoint: .trailing)))
    }
}

private struct Feature: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .frame(width: 24)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct StepDots: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<total, id: \.self) { i in
                Capsule().fill(i == current ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: i == current ? 18 : 6, height: 6)
            }
        }
    }
}
