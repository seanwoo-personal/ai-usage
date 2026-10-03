import AppKit

/// Draws the menu bar item iStat-style: a vertical mini gauge per window, a tiny
/// provider label on top and the percentage (+ reset countdown) underneath.
/// Rendered as a template image so it follows light/dark menu bars automatically.
enum StatusImage {
    struct Block {
        var provider: Provider?
        var top: String
        var bottom: String
        var equalLines = false    // "both" mode: two peer values ("5h 89%" / "7d 76%")
    }

    @MainActor static func blocks(store: UsageStore, settings: AppSettings) -> [Block] {
        let now = store.now
        let showRemaining = settings.showRemaining, showReset = settings.showResetInBar
        return store.activeProviders.map { p in
            let entry = store.entries[p]
            guard let snap = entry?.snapshot else {
                return Block(provider: p, top: "", bottom: entry?.error != nil ? "!" : "…")
            }
            // Real windows only; `fallback` is what to show when the chosen kind doesn't exist.
            // It is never labelled as a weekly or 5-hour limit it isn't.
            let session = snap.window { $0 == .session }?.effective(at: store.now)
            let weekly = snap.window { $0 == .weekly }?.effective(at: store.now)
            let fallback = snap.windows.first?.effective(at: store.now)
            let flag = entry?.error != nil ? "!" : ""
            func pct(_ w: UsageWindow) -> String { w.percentText(showRemaining: showRemaining) }
            func countdown(_ w: UsageWindow) -> String {
                guard showReset, let r = w.resetsAt else { return "" }
                return dayHour(r.timeIntervalSince(now))
            }

            // A mode the provider can't satisfy (e.g. 5-hour on a weekly-only plan) falls back to weekly.
            switch settings.barMode(p) {
            case .both where session != nil && weekly != nil:
                return Block(provider: p, top: "5h " + pct(session!), bottom: "7d " + pct(weekly!) + flag, equalLines: true)
            case .session where session != nil:
                return Block(provider: p, top: countdown(session!), bottom: pct(session!) + flag)
            default:
                guard let w = weekly ?? session ?? fallback else { return Block(provider: p, top: "", bottom: "…") }
                return Block(provider: p, top: countdown(w), bottom: pct(w) + flag)
            }
        }
    }

    /// Always "Xd Yh", e.g. "6d 2h", "0d 3h".
    static func dayHour(_ interval: TimeInterval) -> String {
        let hours = L.minutes(interval) / 60
        return "\(hours / 24)d \(hours % 24)h"
    }

    /// `ink == nil` draws a template image (macOS tints it); pass a colour to draw solid, which stays crisp
    /// on translucent menu bars where template images are shown faded.
    static func render(_ blocks: [Block], height: CGFloat = 22, ink inkColor: NSColor? = nil) -> NSImage {
        let ink = inkColor ?? NSColor.black
        let topAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold), .foregroundColor: ink,
        ]
        let bottomAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: ink,
        ]
        let equalAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold), .foregroundColor: ink,
        ]
        let fallbackAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 7, weight: .bold), .foregroundColor: ink,
        ]
        let logoSize: CGFloat = 15, logoGap: CGFloat = 4, blockGap: CGFloat = 10, pad: CGFloat = 1

        if blocks.isEmpty {
            let img = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "AI Usage") ?? NSImage()
            img.isTemplate = true
            return img
        }

        struct Laid { let logo: NSImage?; let fallback: NSAttributedString?; let top: NSAttributedString; let bottom: NSAttributedString; let logoW: CGFloat; let textW: CGFloat }
        let laid: [Laid] = blocks.map { b in
            let logo = b.provider.flatMap(Logos.image(for:))
            let fallback = logo == nil ? b.provider.map { NSAttributedString(string: String($0.barLabel.prefix(2)), attributes: fallbackAttrs) } : nil
            let top = NSAttributedString(string: b.top, attributes: b.equalLines ? equalAttrs : topAttrs)
            let bottom = NSAttributedString(string: b.bottom, attributes: b.equalLines ? equalAttrs : bottomAttrs)
            let logoW = logo != nil ? logoSize : ceil(fallback?.size().width ?? 0)
            return Laid(logo: logo, fallback: fallback, top: top, bottom: bottom, logoW: logoW,
                        textW: ceil(max(top.size().width, bottom.size().width)))
        }
        let width = pad * 2 + laid.reduce(0) { $0 + $1.logoW + logoGap + $1.textW } + CGFloat(laid.count - 1) * blockGap

        let image = NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { _ in
            var x = pad
            for l in laid {
                if let logo = l.logo {
                    let rect = NSRect(x: x, y: (height - logoSize) / 2, width: logoSize, height: logoSize)
                    let tinted = NSImage(size: rect.size, flipped: false) { r in
                        logo.draw(in: r); ink.set(); r.fill(using: .sourceAtop); return true
                    }
                    tinted.draw(in: rect)
                } else if let f = l.fallback {
                    f.draw(at: NSPoint(x: x, y: (height - f.size().height) / 2))
                }
                x += l.logoW + logoGap
                if l.top.length > 0 {
                    l.top.draw(at: NSPoint(x: x, y: 11))
                    l.bottom.draw(at: NSPoint(x: x, y: l.bottom.size().height < 13 ? 0.5 : -0.5))
                } else {
                    l.bottom.draw(at: NSPoint(x: x, y: (height - l.bottom.size().height) / 2))
                }
                x += l.textW + blockGap
            }
            return true
        }
        image.isTemplate = inkColor == nil
        return image
    }
}

/// The optional system section (CPU · RAM · SSD · network), drawn like Stats: a small label on top,
/// the value below. Each block has a fixed width so the menu bar doesn't shift as numbers change.
enum SystemStatusImage {
    enum Metric: String, CaseIterable, Identifiable {
        case cpu, gpu, memory, disk, sensors, network
        var id: String { rawValue }
        var label: String {
            switch self {
            case .cpu: return "CPU"
            case .gpu: return "GPU"
            case .memory: return "RAM"
            case .disk: return "SSD"
            case .sensors: return L.t("온도", "TEMP")
            case .network: return L.t("네트워크", "Network")
            }
        }
        /// Shown in the menu bar for new installs; GPU and temperature are opt-in.
        static let defaults: [Metric] = [.cpu, .memory, .disk, .network]

        /// The menu bar text for one reading.
        func valueText(_ r: SystemMonitor.Reading) -> String {
            switch self {
            case .cpu: return SystemMath.percentText(r.cpu)
            case .gpu: return SystemMath.percentText(r.gpu)
            case .memory: return SystemMath.percentText(r.memory)
            case .disk: return SystemMath.percentText(r.disk)
            case .sensors: return r.temperature.map { $0.isFinite ? "\(Int($0.rounded()))°" : "–" } ?? "–"
            case .network: return SystemMath.rateText(r.download)
            }
        }
    }

    /// Value colour for a warning or critical reading. Yellow is unreadable on a light menu bar, so
    /// light bars get a darker amber.
    static func alertColor(_ level: SystemLevel, dark: Bool) -> NSColor? {
        switch level {
        case .normal: return nil
        case .warning: return dark ? NSColor(srgbRed: 1, green: 0.84, blue: 0.04, alpha: 1) : NSColor(srgbRed: 0.85, green: 0.5, blue: 0, alpha: 1)
        case .critical: return dark ? NSColor(srgbRed: 1, green: 0.32, blue: 0.3, alpha: 1) : NSColor(srgbRed: 0.85, green: 0.1, blue: 0.1, alpha: 1)
        }
    }

    /// `colors`: tint CPU / RAM / SSD values yellow or red when their level calls for it (needs a solid `ink`).
    static func render(_ r: SystemMonitor.Reading, metrics: [Metric], height: CGFloat = 22, ink inkColor: NSColor? = nil,
                       colors: Bool = false) -> NSImage? {
        guard !metrics.isEmpty else { return nil }
        let ink = inkColor ?? NSColor.black
        let dark = inkColor == .white
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8.5, weight: .semibold), .foregroundColor: ink.withAlphaComponent(0.85),
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: ink,
        ]
        let netAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold), .foregroundColor: ink,
        ]
        let gap: CGFloat = 9
        let percentWidth = ceil(NSAttributedString(string: "100%", attributes: valueAttrs).size().width)
        let netWidth = ceil(NSAttributedString(string: "↓ 999 KB/s", attributes: netAttrs).size().width)

        var parts: [(top: NSAttributedString, bottom: NSAttributedString, width: CGFloat)] = []
        for m in metrics {
            switch m {
            case .network:
                parts.append((NSAttributedString(string: "↑ " + SystemMath.rateText(r.upload), attributes: netAttrs),
                              NSAttributedString(string: "↓ " + SystemMath.rateText(r.download), attributes: netAttrs), netWidth))
            default:
                let label = NSAttributedString(string: m.label, attributes: labelAttrs)
                var attrs = valueAttrs
                if colors, inkColor != nil, let c = alertColor(r.level(m), dark: dark) { attrs[.foregroundColor] = c }
                parts.append((label, NSAttributedString(string: m.valueText(r), attributes: attrs),
                              max(percentWidth, ceil(label.size().width))))
            }
        }
        let width = parts.reduce(0) { $0 + $1.width } + gap * CGFloat(parts.count - 1) + 2
        let image = NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { _ in
            var x: CGFloat = 1
            for p in parts {
                let isNet = p.bottom.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == netAttrs[.font] as? NSFont
                p.top.draw(at: NSPoint(x: x, y: isNet ? 10.5 : 11))
                p.bottom.draw(at: NSPoint(x: x, y: isNet ? 0 : -0.5))
                x += p.width + gap
            }
            return true
        }
        image.isTemplate = inkColor == nil
        return image
    }
}

/// Solid text colour for the menu bar, from the status button's current appearance.
enum MenuBarInk {
    @MainActor static func color(for button: NSStatusBarButton?) -> NSColor {
        isDark(button) ? .white : .black
    }

    @MainActor static func isDark(_ button: NSStatusBarButton?) -> Bool {
        button?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
