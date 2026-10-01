import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private lazy var store = UsageStore(settings: settings)
    private let updater = Updater()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))
        statusItem.button?.imagePosition = .imageOnly

        let host = NSHostingController(rootView: PopoverView().environmentObject(store).environmentObject(settings).environmentObject(updater))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = false

        store.objectWillChange.map { _ in () }
            .merge(with: settings.objectWillChange.map { _ in () })
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] in self?.redraw() }
            .store(in: &bag)

        LoginItem.reconcileAtLaunch()
        redraw()
        store.start()
        updater.start()

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

    private func redraw() {
        let blocks = StatusImage.blocks(store: store, settings: settings)
        statusItem.button?.image = StatusImage.render(blocks)
        statusItem.button?.toolTip = zip(store.activeProviders, blocks)
            .map { "\($0.displayName) \($1.bottom) · \($1.top)" }.joined(separator: "\n")
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            store.refreshIfStale()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

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

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
