import Foundation
import Network
import SystemConfiguration

// Internet check per connection: wired LAN and Wi-Fi are tested separately, each forced through its
// own interface, against Apple's captive-portal check (captive.apple.com), the server macOS itself uses
// to see whether a network has internet. Only a plain HTTP request for that page is sent. Off by default.

/// One physical network connection (wired or Wi-Fi) and, when checked, whether it reaches the internet.
struct ConnectionStatus: Codable, Equatable {
    var kind: String           // "ethernet" or "wifi"
    var interface: String      // BSD name, e.g. "en0"
    var name: String           // display name, e.g. "Ethernet", "Wi-Fi"
    var connected: Bool        // link up with an IPv4 address
    var ipv4: String?
    var isPrimary: Bool        // carries the Mac's default route
    /// "ok", "no_internet", "captive_portal" (a login page answered instead) or "not_checked".
    var internet: String
    var latencyMs: Double?
    var checkedAt: Date?
    var level: String
}

struct InternetStatus: Codable, Equatable {
    /// "ok", "degraded" (the main connection is down but another works), "offline" or "not_checked".
    var state: String
    var level: String
    var checkEnabled: Bool
    var connections: [ConnectionStatus]
}

enum ConnectivityMath {
    enum Result: Equatable { case ok(latencyMs: Double), captivePortal, failed }

    /// Apple's check page answers exactly "<HTML>…Success…</HTML>" with status 200; anything else
    /// (a hotel or office login page, an error) means there's no open internet on that connection.
    static func classify(httpResponse: Data?, connectMs: Double?) -> Result {
        guard let data = httpResponse, let ms = connectMs, ms.isFinite, ms >= 0 else { return .failed }
        let text = String(decoding: data.prefix(4096), as: UTF8.self)
        guard let firstLine = text.split(separator: "\r\n", maxSplits: 1).first, firstLine.hasPrefix("HTTP/") else { return .failed }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return .failed }
        return parts[1] == "200" && text.contains("<BODY>Success</BODY>") ? .ok(latencyMs: (ms * 10).rounded() / 10) : .captivePortal
    }

    /// Per connection: critical when connected but no internet; warning for a login page or a slow link.
    static func connectionLevel(connected: Bool, internet: String, latencyMs: Double?) -> SystemLevel {
        guard connected else { return .normal }   // an unplugged cable or Wi-Fi off isn't a fault by itself
        switch internet {
        case "no_internet": return .critical
        case "captive_portal": return .warning
        case "ok": return (latencyMs ?? 0) >= 500 ? .warning : .normal
        default: return .normal
        }
    }

    /// Whole Mac: offline if nothing reaches the internet, degraded if the main connection fails but another works.
    static func overall(_ connections: [ConnectionStatus], checkEnabled: Bool) -> (state: String, level: SystemLevel) {
        let checked = connections.filter { $0.connected && $0.internet != "not_checked" }
        guard checkEnabled, !checked.isEmpty else {
            return connections.contains(where: \.connected) || !checkEnabled ? ("not_checked", .normal) : ("offline", .critical)
        }
        let okAny = checked.contains { $0.internet == "ok" }
        let primaryOK = checked.first { $0.isPrimary }.map { $0.internet == "ok" } ?? okAny
        if !okAny { return ("offline", .critical) }
        if !primaryOK { return ("degraded", .warning) }
        // The main connection works: a problem on a spare one is worth a look (yellow), not an outage.
        return ("ok", min(checked.map { SystemLevel(name: $0.level) }.max() ?? .normal, .warning))
    }
}

enum ConnectivityProbe {
    /// Physical Ethernet and Wi-Fi interfaces, with link state, address and whether each is the default route.
    static func connections() -> [ConnectionStatus] {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [] }
        let addresses = ipv4Addresses()
        let primary = primaryInterface()
        return all.compactMap { i -> ConnectionStatus? in
            guard let bsd = SCNetworkInterfaceGetBSDName(i) as String?, bsd.hasPrefix("en"),
                  let type = SCNetworkInterfaceGetInterfaceType(i) as String? else { return nil }
            let kind: String
            if type == (kSCNetworkInterfaceTypeIEEE80211 as String) { kind = "wifi" }
            else if type == (kSCNetworkInterfaceTypeEthernet as String) { kind = "ethernet" }
            else { return nil }
            let ip = addresses[bsd]
            // Unused virtual adapters (Thunderbolt ports and the like) are hidden unless they have an address.
            if ip == nil, kind == "ethernet", bsd != "en0" { return nil }
            let name = UntrustedText.clean((SCNetworkInterfaceGetLocalizedDisplayName(i) as String?) ?? bsd)
            return ConnectionStatus(kind: kind, interface: bsd, name: name, connected: ip != nil, ipv4: ip,
                                    isPrimary: bsd == primary, internet: "not_checked", latencyMs: nil, checkedAt: nil, level: "normal")
        }
        .sorted { ($0.kind == "ethernet" ? 0 : 1, $0.interface) < ($1.kind == "ethernet" ? 0 : 1, $1.interface) }
    }

    private static func ipv4Addresses() -> [String: String] {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return [:] }
        defer { freeifaddrs(addrs) }
        var out: [String: String] = [:]
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = p {
            let flags = Int32(ifa.pointee.ifa_flags)
            if let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
               flags & IFF_UP != 0, flags & IFF_RUNNING != 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    if !ip.hasPrefix("169.254.") { out[String(cString: ifa.pointee.ifa_name)] = ip }   // skip self-assigned
                }
            }
            p = ifa.pointee.ifa_next
        }
        return out
    }

    private static func primaryInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "AIUsage" as CFString, nil, nil),
              let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] else { return nil }
        return dict["PrimaryInterface"] as? String
    }

    /// Fetches Apple's check page through one kind of interface only. Blocks the caller for up to `timeout`.
    static func check(kind: String, timeout: TimeInterval = 6) -> ConnectivityMath.Result {
        let params = NWParameters.tcp
        params.requiredInterfaceType = kind == "wifi" ? .wifi : .wiredEthernet
        params.prohibitExpensivePaths = false
        let conn = NWConnection(host: "captive.apple.com", port: 80, using: params)
        let queue = DispatchQueue(label: "aiusage.connectivity")
        let done = DispatchSemaphore(value: 0)
        let start = Date()
        var connectMs: Double?
        var response = Data()
        var finished = false
        func finish() { queue.async { if !finished { finished = true; done.signal() } } }

        func receive() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                if let data { response.append(data) }
                if isComplete || error != nil || response.count >= 4096 { finish() } else { receive() }
            }
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connectMs = Date().timeIntervalSince(start) * 1000
                let request = "GET /hotspot-detect.html HTTP/1.0\r\nHost: captive.apple.com\r\nUser-Agent: AIUsage\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(request.utf8), completion: .contentProcessed { _ in receive() })
            case .failed, .cancelled:
                finish()
            case .waiting:
                finish()   // no route through this interface (e.g. no internet or interface down)
            default:
                break
            }
        }
        conn.start(queue: queue)
        _ = done.wait(timeout: .now() + timeout)
        conn.cancel()
        let (body, ms) = queue.sync { (response, connectMs) }
        return ConnectivityMath.classify(httpResponse: body.isEmpty ? nil : body, connectMs: ms)
    }

    /// Lists connections and, when enabled, checks each connected kind once (Ethernet and Wi-Fi in parallel).
    static func status(checkEnabled: Bool, now: Date = Date()) -> InternetStatus {
        var conns = connections()
        if checkEnabled {
            let kinds = Set(conns.filter(\.connected).map(\.kind))
            var results: [String: ConnectivityMath.Result] = [:]
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: kinds.count) { i in
                let k = Array(kinds)[i]
                let r = check(kind: k)
                lock.lock(); results[k] = r; lock.unlock()
            }
            for i in conns.indices where conns[i].connected {
                // One check per kind: with two wired adapters both get the result for "wired".
                switch results[conns[i].kind] {
                case .ok(let ms)?: conns[i].internet = "ok"; conns[i].latencyMs = ms
                case .captivePortal?: conns[i].internet = "captive_portal"
                case .failed?: conns[i].internet = "no_internet"
                case nil: break
                }
                conns[i].checkedAt = now
            }
        }
        for i in conns.indices {
            conns[i].level = ConnectivityMath.connectionLevel(connected: conns[i].connected, internet: conns[i].internet,
                                                              latencyMs: conns[i].latencyMs).name
        }
        let o = ConnectivityMath.overall(conns, checkEnabled: checkEnabled)
        return InternetStatus(state: o.state, level: o.level.name, checkEnabled: checkEnabled, connections: conns)
    }
}
