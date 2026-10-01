import Foundation
import ServiceManagement

/// "Open at login" rules.
///
/// SMAppService registers whatever bundle is running right now. Registering a copy that later
/// disappears (a build folder, a temp workspace, a mounted DMG, an App Translocation path) leaves a
/// broken login item behind, so registration is only allowed from an installed location.
/// The decisions are pure functions so they can be tested without touching the system.
enum LoginItem {
    private static let recordedPathKey = "loginItemPath"

    // MARK: - Pure decisions

    /// True only for an app bundle under /Applications or ~/Applications.
    static func isInstalledLocation(_ bundlePath: String,
                                    home: String = NSHomeDirectory(),
                                    tempDir: String = NSTemporaryDirectory()) -> Bool {
        let path = normalize(bundlePath, home: home)
        guard path.hasSuffix(".app") else { return false }

        let refusedPrefixes = ["/private/var/folders/", "/private/tmp/", "/Volumes/",
                               withSlash(normalize(tempDir, home: home))]
        if refusedPrefixes.contains(where: { path.hasPrefix($0) }) { return false }

        let refusedComponents: Set<String> = ["DerivedData", ".build", "scratch-workspaces", "AppTranslocation", ".Trash"]
        if path.split(separator: "/").contains(where: { refusedComponents.contains(String($0)) }) { return false }

        let allowedPrefixes = ["/Applications/", withSlash(normalize(home, home: home)) + "Applications/"]
        return allowedPrefixes.contains { path.hasPrefix($0) }
    }

    enum StartupAction: Equatable {
        case nothing
        case reregister   // enabled, but recorded for another location (or not recorded at all)
        case forget       // the user turned it off elsewhere; drop our record
    }

    /// What to do at launch so a login item never keeps pointing at an old location.
    static func startupAction(isEnabled: Bool, recordedPath: String?, currentPath: String,
                              currentIsInstalled: Bool, home: String = NSHomeDirectory()) -> StartupAction {
        guard isEnabled else { return recordedPath == nil ? .nothing : .forget }
        // Never re-point the login item at a temporary copy (e.g. a development build).
        guard currentIsInstalled else { return .nothing }
        let current = normalize(currentPath, home: home)
        return recordedPath.map { normalize($0, home: home) } == current ? .nothing : .reregister
    }

    /// Expands `~`, maps /var and /tmp to their /private targets, collapses `//` and drops a trailing `/`.
    static func normalize(_ raw: String, home: String = NSHomeDirectory()) -> String {
        var p = raw
        if p == "~" { p = home } else if p.hasPrefix("~/") { p = home + p.dropFirst(1) }
        while p.contains("//") { p = p.replacingOccurrences(of: "//", with: "/") }
        for (link, target) in [("/var", "/private/var"), ("/tmp", "/private/tmp")] where p == link || p.hasPrefix(link + "/") {
            p = target + p.dropFirst(link.count)
        }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    private static func withSlash(_ p: String) -> String { p.hasSuffix("/") ? p : p + "/" }

    // MARK: - Effects

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Turns "open at login" on or off. Returns a message for the user when it can't be done.
    /// Turning it off is always allowed; turning it on only from an installed location.
    @discardableResult
    static func setEnabled(_ on: Bool, bundlePath: String = Bundle.main.bundlePath) -> String? {
        if on && !isInstalledLocation(bundlePath) {
            NSLog("AIUsage: refused to register login item from a non-installed location")
            return L.t("앱을 응용 프로그램 폴더로 옮긴 다음 다시 켜 주세요. 지금 위치에서 켜면 나중에 깨진 로그인 항목이 남을 수 있어요.",
                       "Move the app to your Applications folder, then turn this on again. Turning it on from here can leave a broken login item behind.")
        }
        do {
            if on {
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(normalize(bundlePath), forKey: recordedPathKey)
            } else {
                try SMAppService.mainApp.unregister()
                UserDefaults.standard.removeObject(forKey: recordedPathKey)
            }
            return nil
        } catch {
            NSLog("AIUsage: login item change failed: \(error.localizedDescription)")
            return on
                ? L.t("자동 실행을 켜지 못했어요. 시스템 설정 > 일반 > 로그인 항목에서 AI Usage를 확인해 주세요.",
                      "Couldn't turn on open at login. Check AI Usage in System Settings > General > Login Items.")
                : L.t("자동 실행을 끄지 못했어요. 시스템 설정 > 일반 > 로그인 항목에서 꺼 주세요.",
                      "Couldn't turn off open at login. Turn it off in System Settings > General > Login Items.")
        }
    }

    /// At launch: if the login item is on but was registered for a different location
    /// (for example before the app was moved), register it again for this copy.
    static func reconcileAtLaunch(bundlePath: String = Bundle.main.bundlePath) {
        let recorded = UserDefaults.standard.string(forKey: recordedPathKey)
        switch startupAction(isEnabled: isEnabled, recordedPath: recorded, currentPath: bundlePath,
                             currentIsInstalled: isInstalledLocation(bundlePath)) {
        case .nothing:
            break
        case .forget:
            UserDefaults.standard.removeObject(forKey: recordedPathKey)
        case .reregister:
            do {
                try SMAppService.mainApp.unregister()
                try SMAppService.mainApp.register()
                UserDefaults.standard.set(normalize(bundlePath), forKey: recordedPathKey)
                NSLog("AIUsage: login item re-registered for the current location")
            } catch {
                NSLog("AIUsage: login item re-registration failed: \(error.localizedDescription)")
            }
        }
    }
}
