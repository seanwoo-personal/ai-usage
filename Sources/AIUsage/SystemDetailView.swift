import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The popover that opens from a CPU, RAM, SSD or network item in the menu bar, laid out like Stats:
/// the current value with a short history chart, a breakdown, and the busiest processes.
struct SystemDetailView: View {
    let metric: SystemStatusImage.Metric
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch metric {
            case .cpu: cpu
            case .gpu: gpu
            case .memory: memory
            case .disk: disk
            case .sensors: sensors
            case .network: network
            }
            Divider()
            HStack {
                Button(L.t("활성 상태 보기 열기", "Open Activity Monitor")) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
                Spacer()
            }
        }
        .padding(14)
        .frame(width: 290)
    }

    // MARK: CPU

    private var cpu: some View {
        let d = monitor.details
        return VStack(alignment: .leading, spacing: 12) {
            Header(title: "CPU", value: SystemMath.percentText(monitor.reading.cpu), level: monitor.reading.cpuLevel)
            Chart(series: [.init(values: monitor.history.cpu, color: .accentColor)], maxValue: 100)
            Section(L.t("사용량", "Usage")) {
                Row(L.t("시스템", "System"), SystemMath.percentText(d.cpu?.system), dot: .red)
                Row(L.t("사용자", "User"), SystemMath.percentText(d.cpu?.user), dot: .blue)
                Row(L.t("유휴", "Idle"), SystemMath.percentText(d.cpu?.idle), dot: .secondary)
            }
            if !d.cores.isEmpty {
                Section(L.t("코어별", "Cores")) {
                    CoreBars(values: d.cores, types: d.coreTypes)
                    ForEach(HardwareMath.coreGroups(d.cores, kinds: d.coreTypes,
                                                    levels: Array(zip(d.coreLevelNames, d.coreLevelCounts)).map { (name: $0.0, count: $0.1) }) ?? [],
                            id: \.kind) { g in
                        Row(CoreKind.label(g.kind, count: g.count), SystemMath.percentText(g.usagePercent), dot: CoreKind.color(g.kind))
                    }
                }
            }
            Section(L.t("정보", "Details")) {
                if let t = monitor.reading.temperature {
                    Row(L.t("온도 (가장 뜨거운 곳)", "Temperature (hottest)"), Self.celsius(t),
                        valueColor: LevelColor.color(monitor.reading.temperatureLevel))
                }
                Row(L.t("평균 부하", "Load average"),
                    d.load.map { $0.map { String(format: "%.2f", $0) }.joined(separator: " · ") } ?? "–")
                Row(L.t("가동 시간", "Uptime"), d.uptime > 0 ? SystemMath.uptimeText(d.uptime) : "–")
            }
            TopList(title: L.t("CPU를 많이 쓰는 프로세스", "Top processes"), items: monitor.topProcesses) {
                String(format: "%.1f%%", $0.value)
            }
        }
    }

    // MARK: RAM

    private var memory: some View {
        let d = monitor.details
        let m = d.memory
        let bytes = { (v: UInt64?) in SystemMath.bytesText(v.map { Double($0) }) }
        return VStack(alignment: .leading, spacing: 12) {
            Header(title: L.t("메모리", "Memory"), value: SystemMath.percentText(monitor.reading.memory), level: monitor.reading.memoryLevel,
                   caption: m.map { "\(bytes($0.used)) / \(bytes($0.total))" })
            Chart(series: [.init(values: monitor.history.memory, color: .green)], maxValue: 100)
            Section(L.t("사용량", "Usage")) {
                Row(L.t("앱", "App"), bytes(m?.app), dot: .blue)
                Row(L.t("고정", "Wired"), bytes(m?.wired), dot: .orange)
                Row(L.t("압축", "Compressed"), bytes(m?.compressed), dot: .pink)
                Row(L.t("캐시", "Cached files"), bytes(m?.cache), dot: .secondary)
                Row(L.t("여유", "Free"), bytes(m?.free), dot: .clear)
            }
            Section(L.t("정보", "Details")) {
                Row(L.t("메모리 압력", "Memory pressure"),
                    SystemMath.pressureText(monitor.reading.memoryLevel, freePercent: d.memoryFree),
                    valueColor: LevelColor.color(monitor.reading.memoryLevel))
                Row(L.t("스왑", "Swap"), d.swapTotal == 0 ? L.t("사용 안 함", "Not in use")
                    : d.swapUsed.map { "\(bytes($0)) / \(bytes(d.swapTotal))" } ?? "–")
            }
            TopList(title: L.t("메모리를 많이 쓰는 프로세스", "Top processes"), items: monitor.topProcesses) {
                SystemMath.bytesText($0.value)
            }
        }
    }

    // MARK: SSD

    private var disk: some View {
        let d = monitor.details
        let used = d.diskTotal.flatMap { t in d.diskFree.map { Double(t - $0) } }
        return VStack(alignment: .leading, spacing: 12) {
            Header(title: L.t("디스크", "Disk"), value: SystemMath.percentText(monitor.reading.disk), level: monitor.reading.diskLevel,
                   caption: d.diskTotal.map { "\(SystemMath.bytesText(used)) / \(SystemMath.bytesText(Double($0)))" })
            Chart(series: [.init(values: monitor.history.diskRead, color: .blue),
                           .init(values: monitor.history.diskWrite, color: .red)])
            Section(L.t("속도", "Speed")) {
                Row(L.t("읽기", "Read"), SystemMath.rateText(monitor.diskRead), dot: .blue)
                Row(L.t("쓰기", "Write"), SystemMath.rateText(monitor.diskWrite), dot: .red)
            }
            Section(L.t("정보", "Details")) {
                Row(L.t("전체 용량", "Total capacity"), SystemMath.bytesText(d.diskTotal.map { Double($0) }))
                Row(L.t("여유 공간", "Available"), SystemMath.bytesText(d.diskFree.map { Double($0) }))
                Row(L.t("부팅 후 읽음", "Read since startup"), SystemMath.bytesText(d.diskReadTotal.map { Double($0) }))
                Row(L.t("부팅 후 씀", "Written since startup"), SystemMath.bytesText(d.diskWriteTotal.map { Double($0) }))
            }
            ForEach(Array(d.drives.enumerated()), id: \.offset) { _, h in
                Section(L.t("SSD 건강 상태", "SSD health") + (d.drives.count > 1 ? " · \(h.model ?? "")" : "")) {
                    let level = SystemLevel(name: h.level)
                    Row(L.t("상태", "Status"), level == .normal ? L.t("정상", "Good") : level == .warning ? L.t("주의", "Warning") : L.t("위험", "Critical"),
                        valueColor: LevelColor.color(level))
                    Row(L.t("사용한 수명", "Life used"), h.percentageUsed.map { "\($0)%" } ?? "–")
                    Row(L.t("예비 공간", "Available spare"), h.availableSparePercent.map { "\($0)%" } ?? "–")
                    if let t = h.temperatureC { Row(L.t("온도", "Temperature"), "\(t)°C") }
                    Row(L.t("사용 시간", "Power-on hours"), L.t("\(h.powerOnHours)시간", "\(h.powerOnHours) h"))
                    Row(L.t("전원 켠 횟수", "Power cycles"), "\(h.powerCycles)")
                    Row(L.t("비정상 종료", "Unsafe shutdowns"), "\(h.unsafeShutdowns)")
                    Row(L.t("미디어 오류", "Media errors"), "\(h.mediaErrors)", valueColor: h.mediaErrors > 0 ? .orange : nil)
                    Row(L.t("평생 읽음 · 씀", "Lifetime read · written"),
                        "\(SystemMath.bytesText(Double(h.dataReadBytes))) · \(SystemMath.bytesText(Double(h.dataWrittenBytes)))")
                }
            }
            if !d.volumes.isEmpty {
                Section(L.t("연결된 디스크", "Volumes")) {
                    ForEach(Array(d.volumes.enumerated()), id: \.offset) { _, v in
                        VStack(alignment: .leading, spacing: 3) {
                            Row(v.name, SystemMath.percentText(v.usedPercent))
                            Row(L.t("전체 용량", "Total capacity"), SystemMath.bytesText(Double(v.totalBytes)))
                            Row(L.t("여유 공간", "Available"), SystemMath.bytesText(Double(v.freeBytes)))
                        }
                    }
                }
            }
            TopList(title: L.t("디스크를 많이 쓰는 프로세스", "Top processes"), items: monitor.topProcesses,
                    empty: L.t("지금 디스크를 쓰는 프로세스가 없어요.", "No process is using the disk right now.")) {
                SystemMath.rateText($0.value)
            }
        }
    }

    // MARK: GPU

    private var gpu: some View {
        let g = monitor.details.gpu
        return VStack(alignment: .leading, spacing: 12) {
            Header(title: "GPU", value: SystemMath.percentText(monitor.reading.gpu ?? g?.utilizationPercent), level: monitor.reading.gpuLevel,
                   caption: g.map { [$0.model, $0.cores.map { L.t("\($0)코어", "\($0) cores") }].compactMap { $0 }.joined(separator: " · ") })
            Chart(series: [.init(values: monitor.history.gpu, color: .purple)], maxValue: 100)
            Section(L.t("사용량", "Usage")) {
                Row(L.t("전체", "Device"), SystemMath.percentText(g?.utilizationPercent), dot: .purple)
                Row(L.t("렌더러", "Renderer"), SystemMath.percentText(g?.rendererPercent))
                Row(L.t("타일러", "Tiler"), SystemMath.percentText(g?.tilerPercent))
                Row(L.t("사용 중인 메모리", "Memory in use"), SystemMath.bytesText(g?.memoryInUseBytes.map { Double($0) }))
            }
            if g == nil {
                Text(L.t("이 Mac에서는 GPU 사용량을 읽을 수 없어요.", "GPU usage isn't available on this Mac."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Sensors

    static func celsius(_ c: Double?) -> String {
        guard let c, c.isFinite else { return "–" }
        return String(format: "%.0f°C", c)
    }

    private var sensors: some View {
        let s = monitor.details.sensors
        let b = monitor.details.battery
        return VStack(alignment: .leading, spacing: 12) {
            Header(title: L.t("온도", "Temperature"), value: Self.celsius(monitor.reading.temperature ?? s?.cpuMaxC),
                   level: monitor.reading.temperatureLevel,
                   caption: L.t("CPU에서 가장 뜨거운 곳", "Hottest CPU sensor"))
            Chart(series: [.init(values: monitor.history.temperature, color: .orange)], maxValue: 110)
            Section(L.t("온도", "Temperatures")) {
                Row(L.t("CPU 평균", "CPU average"), Self.celsius(s?.cpuAverageC), dot: .orange)
                Row(L.t("CPU 최고", "CPU hottest"), Self.celsius(s?.cpuMaxC))
                if let ssd = s?.ssdC { Row("SSD", Self.celsius(ssd)) }
                if let bat = s?.batteryC { Row(L.t("배터리", "Battery"), Self.celsius(bat)) }
            }
            if let s, !s.fans.isEmpty || s.systemPowerWatts != nil {
                Section(L.t("팬·전력", "Fans and power")) {
                    ForEach(s.fans, id: \.index) { f in
                        Row(s.fans.count > 1 ? L.t("팬 \(f.index + 1)", "Fan \(f.index + 1)") : L.t("팬", "Fan"),
                            "\(Int(f.rpm)) rpm" + (f.maxRpm.map { " / \(Int($0))" } ?? ""))
                    }
                    if let w = s.systemPowerWatts { Row(L.t("시스템 전력", "System power"), String(format: "%.1f W", w)) }
                }
            }
            if let b {
                Section(L.t("배터리", "Battery")) {
                    Row(L.t("충전량", "Charge"), b.percent.map { "\($0)%" } ?? "–")
                    Row(L.t("상태", "State"), b.charging ? L.t("충전 중", "Charging") : b.pluggedIn ? L.t("전원 연결됨", "Plugged in") : L.t("배터리 사용 중", "On battery"))
                    if let m = b.minutesRemaining { Row(b.charging ? L.t("완충까지", "Until full") : L.t("남은 시간", "Time left"), "\(m / 60):" + String(format: "%02d", m % 60)) }
                    if let h = b.healthPercent { Row(L.t("배터리 성능", "Health"), String(format: "%.0f%%", h)) }
                    if let c = b.cycleCount { Row(L.t("충전 횟수", "Cycles"), "\(c)") }
                }
            }
            if let s, !s.temperatures.isEmpty {
                DisclosureGroup(L.t("센서 전체 \(s.temperatures.count)개", "All \(s.temperatures.count) sensors")) {
                    VStack(spacing: 3) {
                        ForEach(s.temperatures, id: \.name) { t in Row(t.name, Self.celsius(t.celsius)) }
                    }
                    .padding(.top, 4)
                }
                .font(.system(size: 11))
            }
            if s == nil && b == nil {
                Text(L.t("이 Mac에서는 온도 센서를 읽을 수 없어요.", "Temperature sensors aren't available on this Mac."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Network

    static func connectionText(_ c: ConnectionStatus, checkEnabled: Bool) -> String {
        guard c.connected else { return L.t("연결 안 됨", "Not connected") }
        switch c.internet {
        case "ok": return L.t("인터넷 정상", "Online") + (c.latencyMs.map { String(format: " · %.0f ms", $0) } ?? "")
        case "no_internet": return L.t("인터넷 안 됨", "No internet")
        case "captive_portal": return L.t("로그인 필요", "Login page")
        default: return checkEnabled ? L.t("확인 중…", "Checking…") : L.t("연결됨", "Connected")
        }
    }

    private var network: some View {
        let d = monitor.details
        let r = monitor.reading
        return VStack(alignment: .leading, spacing: 12) {
            Header(title: L.t("네트워크", "Network"), value: "↓ " + SystemMath.rateText(r.download),
                   caption: "↑ " + SystemMath.rateText(r.upload))
            Chart(series: [.init(values: monitor.history.download, color: .blue),
                           .init(values: monitor.history.upload, color: .red)])
            Section(L.t("속도", "Speed")) {
                Row(L.t("다운로드", "Download"), SystemMath.rateText(r.download), dot: .blue)
                Row(L.t("업로드", "Upload"), SystemMath.rateText(r.upload), dot: .red)
            }
            Section(L.t("정보", "Details")) {
                Row(L.t("연결", "Interface"), d.interface ?? "–")
                Row(L.t("내부 IP", "Local IP"), d.localIP ?? "–")
                Row(L.t("부팅 후 받음", "Received since startup"), SystemMath.bytesText(d.netReceivedTotal.map { Double($0) }))
                Row(L.t("부팅 후 보냄", "Sent since startup"), SystemMath.bytesText(d.netSentTotal.map { Double($0) }))
            }
            if let net = monitor.internet, !net.connections.isEmpty {
                Section(L.t("인터넷 연결", "Internet")) {
                    ForEach(net.connections, id: \.interface) { c in
                        Row(c.name + (c.isPrimary && net.connections.filter(\.connected).count > 1 ? L.t(" (주 연결)", " (main)") : ""),
                            Self.connectionText(c, checkEnabled: net.checkEnabled), valueColor: LevelColor.color(SystemLevel(name: c.level)))
                    }
                    if !net.checkEnabled {
                        Text(L.t("설정에서 \"인터넷 연결 확인\"을 켜면 연결마다 인터넷이 되는지와 응답 속도를 확인해요.",
                                 "Turn on \"Check internet connection\" in Settings to test each connection and its response time."))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            if let w = d.wifi {
                Section("Wi-Fi") {
                    Row(L.t("신호", "Signal"), w.rssiDbm.map { "\($0) dBm" } ?? L.t("연결 안 됨", "Not connected"))
                    if let n = w.noiseDbm { Row(L.t("잡음", "Noise"), "\(n) dBm") }
                    if let c = w.channel { Row(L.t("채널", "Channel"), "\(c)" + (w.bandGhz.map { " · " + String(format: $0 == 2.4 ? "%.1f GHz" : "%.0f GHz", $0) } ?? "")) }
                    if let t = w.transmitRateMbps { Row(L.t("전송 속도", "Transmit rate"), String(format: "%.0f Mbps", t)) }
                }
            }
            TopList(title: L.t("네트워크를 많이 쓰는 프로세스", "Top processes"), items: monitor.topProcesses,
                    empty: L.t("측정 중… (약 5초)", "Measuring… (about 5 s)")) {
                SystemMath.rateText($0.value)
            }
        }
    }
}

// MARK: - Pieces

/// Yellow / red for warning / critical readings in the popovers.
enum LevelColor {
    static func color(_ level: SystemLevel) -> Color? {
        switch level {
        case .normal: return nil
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

private struct Header: View {
    let title: String
    let value: String
    var level = SystemLevel.normal
    var caption: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(value).font(.system(size: 20, weight: .semibold).monospacedDigit())
                    .foregroundStyle(LevelColor.color(level) ?? .primary)
                if let caption {
                    Text(caption).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct Section<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            content
        }
    }
}

private struct Row: View {
    let label: String
    let value: String
    var dot: Color?
    var valueColor: Color?
    init(_ label: String, _ value: String, dot: Color? = nil, valueColor: Color? = nil) {
        self.label = label
        self.value = value
        self.dot = dot
        self.valueColor = valueColor
    }

    var body: some View {
        HStack(spacing: 6) {
            if let dot {
                Circle().fill(dot).frame(width: 7, height: 7)
                    .overlay(Circle().stroke(Color.secondary.opacity(dot == .clear ? 0.6 : 0), lineWidth: 1))
            }
            Text(label).font(.system(size: 12))
            Spacer()
            Text(value).font(.system(size: 12).monospacedDigit()).foregroundStyle(valueColor ?? .primary)
        }
    }
}

/// Line chart of recent samples. Without `maxValue` the scale follows the largest value shown.
private struct Chart: View {
    struct Series { let values: [Double]; let color: Color }
    let series: [Series]
    var maxValue: Double?

    var body: some View {
        let top = maxValue ?? max(series.flatMap(\.values).max() ?? 0, 1)
        GeometryReader { geo in
            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    Path { p in
                        let y = geo.size.height * CGFloat(i + 1) / 4
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
                }
                ForEach(series.indices, id: \.self) { i in
                    let s = series[i]
                    let points = Self.points(s.values, in: geo.size, top: top)
                    if points.count > 1 {
                        Path { p in
                            p.move(to: CGPoint(x: points[0].x, y: geo.size.height))
                            points.forEach { p.addLine(to: $0) }
                            p.addLine(to: CGPoint(x: points[points.count - 1].x, y: geo.size.height))
                            p.closeSubpath()
                        }
                        .fill(s.color.opacity(0.12))
                        Path { p in p.addLines(points) }
                            .stroke(s.color, style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
                    }
                }
            }
        }
        .frame(height: 56)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Newest sample at the right edge; a full history spans the whole width.
    static func points(_ values: [Double], in size: CGSize, top: Double, capacity: Int = SystemMonitor.historyLength) -> [CGPoint] {
        guard top > 0 else { return [] }
        let step = size.width / CGFloat(max(capacity - 1, 1))
        let start = size.width - step * CGFloat(values.count - 1)
        return values.enumerated().map { i, v in
            let f = max(0, min(1, v / top))
            return CGPoint(x: start + step * CGFloat(i), y: size.height - CGFloat(f) * (size.height - 3) - 1)
        }
    }
}

/// Names and colours for core groups.
enum CoreKind {
    static func label(_ kind: String, count: Int) -> String {
        switch kind {
        case "efficiency": return L.t("효율 코어 \(count)개", "Efficiency cores (\(count))")
        case "performance": return L.t("성능 코어 \(count)개", "Performance cores (\(count))")
        case "super": return L.t("슈퍼 코어 \(count)개", "Super cores (\(count))")
        default: return "\(kind.capitalized) (\(count))"
        }
    }

    static func color(_ kind: String?) -> Color {
        switch kind {
        case "efficiency": return .green
        case "super": return .purple
        default: return .accentColor
        }
    }
}

private struct CoreBars: View {
    let values: [Double?]
    var types: [String]?

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(values.indices, id: \.self) { i in
                let v = values[i] ?? 0
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.12))
                    RoundedRectangle(cornerRadius: 2).fill(CoreKind.color(types?[safe: i]))
                        .frame(height: max(1, 30 * CGFloat(v / 100)))
                }
                .frame(height: 30)
                .help("\(i + 1): \(SystemMath.percentText(values[i]))")
            }
        }
    }
}

private struct TopList: View {
    let title: String
    let items: [ProcessUsage]
    var empty: String = L.t("불러오는 중…", "Loading…")
    let format: (ProcessUsage) -> String

    var body: some View {
        Section(title) {
            if items.isEmpty {
                Text(empty).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(items) { p in
                HStack(spacing: 6) {
                    Image(nsImage: Self.icon(for: p.pid)).resizable().frame(width: 14, height: 14)
                    Text(p.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(format(p)).font(.system(size: 12).monospacedDigit())
                }
            }
        }
    }

    static func icon(for pid: Int32) -> NSImage {
        NSRunningApplication(processIdentifier: pid)?.icon
            ?? NSWorkspace.shared.icon(for: .unixExecutable)
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
