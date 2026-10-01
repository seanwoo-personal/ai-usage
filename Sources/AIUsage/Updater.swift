import AppKit

/// Checks GitHub for a newer release and installs it with the installer bundled in the app,
/// so updates get exactly the same checks as the one-line install (pinned release, SHA-256,
/// bundle ID, signature integrity, staged swap with rollback).
@MainActor
final class Updater: ObservableObject {
    struct Release: Equatable {
        let version: String   // "1.2.0"
        let tag: String       // "v1.2.0"
        let page: URL         // release notes on github.com
    }

    @Published private(set) var available: Release?
    @Published private(set) var lastChecked: Date?
    @Published private(set) var checking = false
    @Published private(set) var installing = false
    /// A sentence for the user when a check or install didn't work, or nil.
    @Published private(set) var problem: String?

    static let repo = "seanwoo-personal/ai-usage"
    static let checkEvery: TimeInterval = 24 * 3600
    private static let autoKey = "autoCheckUpdates", lastKey = "lastUpdateCheck"

    let current: String
    private let defaults: UserDefaults
    private var timer: Timer?

    init(current: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0",
         defaults: UserDefaults = .standard) {
        self.current = current
        self.defaults = defaults
        defaults.register(defaults: [Self.autoKey: true])
        lastChecked = defaults.object(forKey: Self.lastKey) as? Date
    }

    var autoCheck: Bool {
        get { defaults.bool(forKey: Self.autoKey) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Self.autoKey) }
    }

    /// Only an installed copy updates itself (a build or DMG copy must not overwrite the installed app).
    var canInstall: Bool { LoginItem.isInstalledLocation(Bundle.main.bundlePath) }

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkIfDue() }
        }
    }

    private func checkIfDue() {
        guard autoCheck else { return }
        if let last = lastChecked, Date().timeIntervalSince(last) < Self.checkEvery { return }
        Task { await check() }
    }

    func check() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("AIUsage/\(current)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200, let release = Self.parseRelease(data) else {
                problem = L.t("새 버전을 확인하지 못했어요. 나중에 다시 확인할게요.", "Couldn't check for a new version. Will try again later.")
                return
            }
            problem = nil
            lastChecked = Date()
            defaults.set(lastChecked, forKey: Self.lastKey)
            available = Self.isNewer(release.version, than: current) ? release : nil
        } catch {
            problem = L.t("인터넷에 연결되지 않아 새 버전을 확인하지 못했어요.", "Couldn't check for a new version while offline.")
        }
    }

    /// Runs the bundled installer pinned to the available release. The installer quits this app
    /// only after the new one has passed every check, swaps it in, and reopens it. On failure the
    /// current app stays (and is reopened if it had been quit).
    func install() {
        guard let release = available, !installing else { return }
        guard canInstall else {
            problem = L.t("응용 프로그램 폴더에 설치된 앱에서만 업데이트할 수 있어요.", "Updates run only from the app in your Applications folder.")
            return
        }
        guard let script = Bundle.main.url(forResource: "install", withExtension: "sh") else {
            problem = L.t("업데이트 도구를 찾지 못했어요. 설치 명령으로 직접 업데이트해 주세요.", "The updater is missing. Please update with the install command.")
            return
        }
        let logDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AI Usage", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let log = logDir.appendingPathComponent("update.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: log)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path]
        p.environment = ["AIUSAGE_VERSION": release.tag, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                         "HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory()]
        p.standardOutput = handle
        p.standardError = handle
        p.terminationHandler = { proc in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.installing = false
                if proc.terminationStatus != 0 {
                    let tail = (try? String(contentsOf: log, encoding: .utf8))?
                        .split(separator: "\n").last { $0.hasPrefix("✗") }.map { String($0.dropFirst(2)) }
                    self.problem = tail ?? L.t("업데이트에 실패했어요. 지금 버전은 그대로예요.", "The update failed. Your current version is unchanged.")
                }
            }
        }
        do {
            try p.run()
            installing = true
            problem = nil
        } catch {
            problem = L.t("업데이트를 시작하지 못했어요.", "Couldn't start the update.")
        }
    }

    /// Test hook: pretend a release was found (for rendering checks).
    func testOffer(_ release: Release) { available = release }

    // MARK: - Pure helpers (tested)

    /// "1.10.0" > "1.9.3". Non-numeric parts count as 0; missing parts as 0.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] { v.split(separator: ".").map { Int($0) ?? 0 } }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// A published (not draft, not pre-release) release with a vX.Y.Z tag and a github.com page.
    nonisolated static func parseRelease(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              tag.range(of: #"^v[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}$"#, options: .regularExpression) != nil,
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
              let pageString = json["html_url"] as? String, let page = URL(string: pageString),
              page.scheme == "https", page.host == "github.com" else { return nil }
        return Release(version: String(tag.dropFirst()), tag: tag, page: page)
    }
}
