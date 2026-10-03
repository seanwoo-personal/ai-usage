import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private lazy var store = UsageStore(settings: settings)
    private let updater = Updater()
    private var statusItem: NSStatusItem!
    /// Optional items for CPU, RAM, SSD and network (Settings → system status), one per metric
    /// so each opens its own detail popover.
    private var systemItems: [SystemStatusImage.Metric: NSStatusItem] = [:]
    private let monitor = SystemMonitor()
    private let popover = NSPopover()
    private let detailPopover = NSPopover()
    private var detailMetric: SystemStatusImage.Metric?
    private var bag = Set<AnyCancellable>()
    private var appearanceWatch: [NSKeyValueObservation] = []
    /// Whether the menu bar was dark at the last redraw. macOS reports effectiveAppearance again every
    /// time a status image changes, so redraw only when light/dark actually flips (otherwise it loops).
    private var menuBarDark: Bool?
    /// What each button currently shows, so an unchanged image isn't set again.
    private var shownImageKeys: [ObjectIdentifier: String] = [:]
    private var statusTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))
        statusItem.button?.imagePosition = .imageOnly
        statusItem.autosaveName = "AIUsage.usage"   // keeps the position after ⌘-dragging

        let host = NSHostingController(rootView: PopoverView().environmentObject(store).environmentObject(settings).environmentObject(updater))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = false
        detailPopover.behavior = .transient
        detailPopover.animates = false
        detailPopover.delegate = self

        store.objectWillChange.map { _ in () }
            .merge(with: settings.objectWillChange.map { _ in () })
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] in self?.redraw() }
            .store(in: &bag)
        settings.objectWillChange.map { _ in () }
            .merge(with: monitor.objectWillChange.map { _ in () })
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] in self?.updateSystemItem() }
            .store(in: &bag)
        updateSystemItem()

        // Solid-colour images must be redrawn when the menu bar switches between light and dark.
        appearanceWatch.append(statusItem.button!.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.appearanceMayHaveChanged() }
        })

        settings.$shareStatus.removeDuplicates().sink { [weak self] on in
            Task { @MainActor in self?.setStatusSaving(on) }
        }.store(in: &bag)

        LoginItem.reconcileAtLaunch()
        redraw()
        store.start()
        updater.start()
        // Diagnostics: AIUSAGE_DEBUG_AUTOUPDATE=1 checks and installs an available update without any UI.
        if ProcessInfo.processInfo.environment["AIUSAGE_DEBUG_AUTOUPDATE"] == "1" {
            Task { await updater.check(); updater.install() }
        }

        AppActions.showOnboarding = { [weak self] in
            guard let self else { return }
            self.popover.performClose(nil)
            OnboardingWindow.show(store: self.store, settings: self.settings)
        }
        if !settings.onboarded { AppActions.showOnboarding() }
        // Diagnostics: AIUSAGE_DEBUG_LOGIN=claude|codex opens that login window at launch.
        if let p = ProcessInfo.processInfo.environment["AIUSAGE_DEBUG_LOGIN"].flatMap(Provider.init(rawValue:)) {
            store.logInOnWeb(p)
        }
    }

    private func appearanceMayHaveChanged() {
        let dark = MenuBarInk.isDark(statusItem.button)
        guard dark != menuBarDark else { return }
        menuBarDark = dark
        shownImageKeys = [:]
        redraw()
        updateSystemItem()
    }

    /// Sets the button image only when what it shows changed.
    private func setImage(_ button: NSStatusBarButton?, key: String, render: () -> NSImage?) {
        guard let button else { return }
        let fullKey = key + (MenuBarInk.isDark(button) ? "|dark" : "|light")
        guard shownImageKeys[ObjectIdentifier(button)] != fullKey else { return }
        shownImageKeys[ObjectIdentifier(button)] = fullKey
        button.image = render()
    }

    private func redraw() {
        let blocks = StatusImage.blocks(store: store, settings: settings)
        setImage(statusItem.button, key: blocks.map { "\($0.provider?.rawValue ?? "-")\($0.top)\($0.bottom)\($0.equalLines)" }.joined(separator: ";")) {
            StatusImage.render(blocks, ink: MenuBarInk.color(for: statusItem.button))
        }
        statusItem.button?.toolTip = zip(store.activeProviders, blocks)
            .map { "\($0.displayName) \($1.bottom) · \($1.top)" }.joined(separator: "\n")
    }

    /// Shows, updates or removes the system items, and runs the monitor only while one is shown.
    private func updateSystemItem() {
        let metrics = settings.showSystem ? settings.orderedSystemMetrics : []
        for (m, item) in systemItems where !metrics.contains(m) {
            if detailMetric == m { detailPopover.performClose(nil) }
            if let b = item.button { shownImageKeys[ObjectIdentifier(b)] = nil }
            NSStatusBar.system.removeStatusItem(item)
            systemItems[m] = nil
        }
        // The monitor also runs, more slowly, when nothing is shown but the status is saved for other tools.
        monitor.setInterval(metrics.isEmpty ? 5 : 1)
        guard !metrics.isEmpty else {
            if settings.shareStatus { if !monitor.isRunning { monitor.start() } } else if monitor.isRunning { monitor.stop() }
            return
        }
        // New items appear to the left of existing ones, so create them right to left.
        for m in metrics.reversed() where systemItems[m] == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "AIUsage.system.\(m.rawValue)"
            item.button?.target = self
            item.button?.action = #selector(toggleDetail(_:))
            item.button?.imagePosition = .imageOnly
            systemItems[m] = item
        }
        monitor.shown = Set(metrics)
        if !monitor.isRunning { monitor.start() }
        let r = monitor.reading
        for (m, item) in systemItems {
            let key: String
            switch m {
            case .network: key = SystemMath.rateText(r.upload) + SystemMath.rateText(r.download)
            default: key = m.valueText(r) + "\(r.level(m))"
            }
            setImage(item.button, key: key + "\(settings.systemColors)") {
                SystemStatusImage.render(r, metrics: [m], ink: MenuBarInk.color(for: item.button), colors: settings.systemColors)
            }
            item.button?.toolTip = m == .network
                ? "↑ \(SystemMath.rateText(r.upload))  ↓ \(SystemMath.rateText(r.download))"
                : "\(m.label) \(m.valueText(r))"
        }
    }

    /// Saves this Mac's status every 5 seconds for `AIUsage status` / `AIUsage mcp`; removes it when turned off.
    private func setStatusSaving(_ on: Bool) {
        statusTimer?.invalidate()
        statusTimer = nil
        guard on else {
            try? FileManager.default.removeItem(at: StatusFile.url)
            return
        }
        statusTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.saveStatus() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.saveStatus() }
    }

    private func saveStatus() {
        guard settings.shareStatus, monitor.isRunning else { return }
        let now = Date()
        let usage = store.activeProviders.map { p in
            StatusSnapshot.aiUsage(provider: p, connection: settings.connections[p] ?? .none,
                                   snapshot: store.entries[p]?.snapshot, error: store.entries[p]?.error, now: now)
        }
        let snapshot = StatusSnapshot(generatedAt: now, source: "app", appVersion: updater.current,
                                      host: SystemProbe.host(), system: monitor.statusSnapshot(), aiUsage: usage)
        do { try StatusFile.write(snapshot) } catch { NSLog("AIUsage: couldn't save status: \(error)") }
    }

    @objc private func toggleDetail(_ sender: Any?) {
        guard let button = sender as? NSStatusBarButton,
              let metric = systemItems.first(where: { $0.value.button === button })?.key else { return }
        if detailPopover.isShown {
            let same = detailMetric == metric
            detailPopover.close()
            if same { return }
        }
        popover.performClose(nil)
        detailMetric = metric
        monitor.focus = metric
        let host = NSHostingController(rootView: SystemDetailView(metric: metric, monitor: monitor))
        host.sizingOptions = .preferredContentSize
        detailPopover.contentViewController = host
        NSApp.activate(ignoringOtherApps: true)
        detailPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        detailPopover.contentViewController?.view.window?.makeKey()
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = (sender as? NSStatusBarButton) ?? statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            detailPopover.performClose(nil)
            store.refreshIfStale()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

extension AppDelegate: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        // Switching metrics closes and immediately reopens the popover; keep the new focus then.
        guard (notification.object as? NSPopover) === detailPopover, !detailPopover.isShown else { return }
        detailMetric = nil
        monitor.focus = nil
    }
}

// `AIUsage status | top | mcp | help`: read-only commands; they never start the menu bar app.
if let code = StatusCLI.run(CommandLine.arguments) { exit(code) }

// `AIUsage --render-preview out.png` draws sample menu bar images (used to check the layout).
if let i = CommandLine.arguments.firstIndex(of: "--render-preview"), i + 1 < CommandLine.arguments.count {
    let samples: [[StatusImage.Block]] = [
        [.init(provider: .claude, top: "2d 4h", bottom: "63%"),
         .init(provider: .codex, top: "6d 2h", bottom: "75%")],
        [.init(provider: .claude, top: "5h 89%", bottom: "7d 76%", equalLines: true),
         .init(provider: .codex, top: "", bottom: "!")],
    ]
    let scale: CGFloat = 4
    let images = samples.map { StatusImage.render($0) }
    let w = (images.map(\.size.width).max() ?? 100) + 16, h: CGFloat = 22 * CGFloat(images.count * 2) + 8
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * scale), pixelsHigh: Int(h * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: w, height: h)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    var y = h - 4
    for (idx, img) in images.enumerated() {
        for dark in [false, true] {
            y -= 22
            (dark ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
            NSRect(x: 0, y: y, width: w, height: 22).fill()
            let tinted = NSImage(size: img.size, flipped: false) { r in
                img.draw(in: r)
                (dark ? NSColor.white : NSColor.black).set()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(at: NSPoint(x: 8, y: y), from: .zero, operation: .sourceOver, fraction: 1)
        }
        _ = idx
    }
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}

// `AIUsage --render-details <dir>` samples for a few seconds, then draws each detail popover
// (light and dark) to PNG files without showing any window.
if let i = CommandLine.arguments.firstIndex(of: "--render-details"), i + 1 < CommandLine.arguments.count {
    let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1], isDirectory: true)
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        let monitor = SystemMonitor()
        monitor.start()
        for metric in SystemStatusImage.Metric.allCases {
            monitor.focus = metric
            RunLoop.main.run(until: Date().addingTimeInterval(metric == .cpu ? 9 : metric == .network ? 8 : 5))
            for dark in [false, true] {
                let view = NSHostingView(rootView: SystemDetailView(metric: metric, monitor: monitor)
                    .background(dark ? Color(white: 0.16) : Color(white: 0.97)))
                view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                view.frame.size = view.fittingSize
                view.layoutSubtreeIfNeeded()
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: rep)
                try! rep.representation(using: .png, properties: [:])!
                    .write(to: dir.appendingPathComponent("\(metric.rawValue)-\(dark ? "dark" : "light").png"))
            }
        }
    }
    // Menu bar samples with normal / warning / critical values, light and dark.
    MainActor.assumeIsolated {
        var r = SystemMonitor.Reading(cpu: 23, memory: 81, disk: 67, upload: 12_000, download: 340_000)
        let rows: [(SystemMonitor.Reading) -> SystemMonitor.Reading] = [
            { $0 },
            { var x = $0; x.cpu = 78; x.cpuLevel = .warning; x.memoryLevel = .warning; return x },
            { var x = $0; x.cpu = 97; x.cpuLevel = .critical; x.memoryLevel = .critical; x.disk = 96; x.diskLevel = .critical; return x },
        ]
        let scale: CGFloat = 4, w: CGFloat = 260, h: CGFloat = 22 * 6 + 8
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * scale), pixelsHigh: Int(h * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        var y = h - 4
        for make in rows {
            r = make(SystemMonitor.Reading(cpu: 23, memory: 81, disk: 67, upload: 12_000, download: 340_000))
            for dark in [false, true] {
                y -= 22
                (dark ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                NSRect(x: 0, y: y, width: w, height: 22).fill()
                SystemStatusImage.render(r, metrics: SystemStatusImage.Metric.allCases, ink: dark ? .white : .black, colors: true)?
                    .draw(at: NSPoint(x: 8, y: y), from: .zero, operation: .sourceOver, fraction: 1)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try! rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("menubar-colors.png"))
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
