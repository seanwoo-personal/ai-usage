import Foundation

/// Minimal two-language support: Korean when it is the user's first preferred language, English otherwise.
enum L {
    static let isKorean = Locale.preferredLanguages.first?.hasPrefix("ko") ?? false

    static func t(_ ko: String, _ en: String) -> String { isKorean ? ko : en }

    /// Compact countdown for the menu bar: "2d4h", "5h12m", "42m".
    static func compact(_ interval: TimeInterval) -> String {
        let mins = max(0, Int(interval / 60))
        let d = mins / 1440, h = (mins % 1440) / 60, m = mins % 60
        if d > 0 { return "\(d)d\(h)h" }
        if h > 0 { return "\(h)h\(m)m" }
        return "\(m)m"
    }

    /// Readable countdown for the popover: "3일 4시간 후" / "in 3d 4h".
    static func countdown(_ interval: TimeInterval) -> String {
        let mins = max(0, Int(interval / 60))
        let d = mins / 1440, h = (mins % 1440) / 60, m = mins % 60
        let body: String
        if isKorean {
            if d > 0 { body = "\(d)일 \(h)시간" } else if h > 0 { body = "\(h)시간 \(m)분" } else { body = "\(m)분" }
            return body + " 후"
        }
        if d > 0 { body = "\(d)d \(h)h" } else if h > 0 { body = "\(h)h \(m)m" } else { body = "\(m)m" }
        return "in " + body
    }

    static func ago(_ date: Date, now: Date = Date()) -> String {
        let mins = Int(now.timeIntervalSince(date) / 60)
        if mins < 1 { return t("방금", "just now") }
        if mins < 60 { return t("\(mins)분 전", "\(mins)m ago") }
        let h = mins / 60
        if h < 48 { return t("\(h)시간 전", "\(h)h ago") }
        return t("\(h / 24)일 전", "\(h / 24)d ago")
    }

    private static let resetFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("MMMdEEEjmm")
        return f
    }()

    static func resetDate(_ date: Date) -> String { resetFormatter.string(from: date) }
}
