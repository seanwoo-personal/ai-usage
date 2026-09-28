import SwiftUI

/// "Is this safe?" — shown before any login button.
struct TrustBlock: View {
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            Label(L.t("안심하고 연결하세요", "Safe to connect"), systemImage: "lock.shield.fill")
                .font(.system(size: compact ? 12 : 13, weight: .semibold))
                .foregroundStyle(.green)
            TrustLine(L.t("남은 사용량(%)과 리셋 시간만 읽어요. 대화 내용·파일·결제 정보는 보지 않아요.",
                          "Reads only remaining usage (%) and reset times — never your chats, files or billing."))
            TrustLine(L.t("로그인 정보는 이 Mac 밖으로 나가지 않아요. 개발자 서버는 없고, Anthropic·OpenAI 공식 서버와만 통신해요.",
                          "Your login never leaves this Mac. There's no developer server — only Anthropic's and OpenAI's own."))
            TrustLine(L.t("언제든 설정에서 연결을 해제할 수 있어요. 웹 로그인은 해제할 때 앱에 남은 로그인도 함께 지워져요.",
                          "Disconnect any time in Settings. For web logins, that also erases the login saved in the app."))
        }
        .font(compact ? .caption : .callout)
        .padding(compact ? 10 : 14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.08)))
    }
}

private struct TrustLine: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.green)
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Both ways to connect one service, each with a plain explanation of what it reads.
/// If the CLI is already logged in on this Mac, that option comes first and connects in one click.
struct ConnectPanel: View {
    @EnvironmentObject var store: UsageStore
    let provider: Provider
    var compact = false

    var body: some View {
        let cliReady = provider.isSetUp
        let busy = store.loggingIn.contains(provider)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProviderLogo(provider: provider, size: compact ? 18 : 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName).font(compact ? .system(size: 13, weight: .semibold) : .headline)
                    Text(provider == .claude
                         ? L.t("Pro·Max 구독의 5시간·주간 한도", "5-hour and weekly limits on Pro/Max")
                         : L.t("ChatGPT 요금제에 포함된 Codex 한도", "Codex limits on your ChatGPT plan"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L.t("열린 로그인 창에서 로그인해 주세요. 끝나면 자동으로 연결돼요.",
                             "Log in in the window that opened. It connects automatically when you're done."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if cliReady {
                cliOption(ready: true, recommended: true)
                webOption(recommended: false)
            } else {
                webOption(recommended: true)
                cliOption(ready: false, recommended: false)
            }
        }
        .padding(compact ? 12 : 14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
    }

    private func cliOption(ready: Bool, recommended: Bool) -> some View {
        OptionRow(
            icon: "terminal",
            title: L.t("\(provider.cliName)로 연결", "Connect with \(provider.cliName)"),
            badge: ready ? L.t("이 Mac에 로그인되어 있어요", "Logged in on this Mac") : nil,
            text: ready
                ? L.t("버튼만 누르면 바로 연결돼요. 따로 로그인할 필요 없어요.", "One click and you're connected — no extra login.")
                : L.t("이 Mac에서 \(provider.cliName) 로그인을 찾지 못했어요. \(provider.cliName)를 쓴다면 터미널에서 로그인한 뒤 연결할 수 있어요.",
                      "No \(provider.cliName) login on this Mac. If you use it, log in from Terminal first."),
            details: provider == .claude
                ? L.t("Claude Code가 macOS 키체인에 저장해 둔 로그인 정보를 읽기만 해요. 수정하거나 다른 곳에 복사·저장하지 않고, Anthropic 공식 서버(api.anthropic.com)에 남은 사용량을 물어볼 때만 써요. macOS가 허용 여부를 물으면 '항상 허용'을 눌러 주세요 — 그래야 다시 묻지 않아요.",
                      "Reads — never changes, copies or stores — the login Claude Code keeps in your macOS Keychain, only to ask Anthropic's own server (api.anthropic.com) for your remaining usage. If macOS asks, choose “Always Allow” so it won't ask again.")
                : L.t("Codex CLI가 저장해 둔 로그인 파일(~/.codex/auth.json)을 읽기만 해요. 수정하거나 다른 곳에 복사·저장하지 않고, OpenAI 공식 서버(chatgpt.com)에 남은 사용량을 물어볼 때만 써요.",
                      "Reads — never changes, copies or stores — the login file Codex CLI keeps (~/.codex/auth.json), only to ask OpenAI's own server (chatgpt.com) for your remaining usage."),
            buttonTitle: ready ? L.t("바로 연결", "Connect") : L.t("터미널에서 로그인", "Log in in Terminal"),
            prominent: recommended,
            action: { store.useCLI(provider) })
    }

    private func webOption(recommended: Bool) -> some View {
        OptionRow(
            icon: "globe",
            title: L.t("\(provider.website) 계정으로 로그인", "Log in with \(provider.website)"),
            badge: nil,
            text: L.t("\(provider.cliName)를 쓰지 않아도 돼요. 평소 쓰는 계정으로 한 번만 로그인하면 끝이에요.",
                      "No \(provider.cliName) needed. Log in once with the account you already use."),
            details: L.t("\(provider.website) 공식 로그인 페이지가 그대로 열려요. 비밀번호는 그 페이지에 직접 입력되고, AI Usage는 읽거나 저장하지 않아요. 로그인 상태는 Safari와 같은 방식으로 이 앱 안에만 보관되고, 설정에서 '연결 해제'를 누르면 지워져요.",
                         "The official \(provider.website) login page opens as-is. Your password goes straight into that page; AI Usage never reads or stores it. The login is kept inside this app the way Safari keeps it, and “Disconnect” erases it."),
            buttonTitle: L.t("로그인", "Log in"),
            prominent: recommended,
            action: { store.logInOnWeb(provider) })
    }
}

private struct OptionRow: View {
    let icon: String
    let title: String
    let badge: String?
    let text: String
    let details: String
    let buttonTitle: String
    let prominent: Bool
    let action: () -> Void
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon).frame(width: 18).foregroundStyle(.secondary).padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 12.5, weight: .semibold))
                    if let badge {
                        Label(badge, systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.green)
                    }
                    Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showDetails.toggle() }
                    } label: {
                        Label(L.t("무엇을 읽나요?", "What does it read?"), systemImage: showDetails ? "chevron.down" : "chevron.right")
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    if showDetails {
                        Text(details)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                    }
                }
                Spacer(minLength: 6)
                if prominent {
                    Button(buttonTitle, action: action).buttonStyle(.borderedProminent).controlSize(.small)
                } else {
                    Button(buttonTitle, action: action).controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(prominent ? 0.18 : 0.08)))
    }
}
