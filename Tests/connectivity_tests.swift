import Foundation

/// Internet check decisions from fixed responses. No network is used here.
enum ConnectivityTests {
    static func conn(_ kind: String, connected: Bool = true, internet: String, primary: Bool = false, ms: Double? = nil) -> ConnectionStatus {
        let level = ConnectivityMath.connectionLevel(connected: connected, internet: internet, latencyMs: ms).name
        return ConnectionStatus(kind: kind, interface: kind == "wifi" ? "en1" : "en0", name: kind, connected: connected, ipv4: nil,
                                isPrimary: primary, internet: internet, latencyMs: ms, checkedAt: nil, level: level)
    }

    static func run() {
        print("Internet check")
        let apple = Data("HTTP/1.0 200 OK\r\nContent-Type: text/html\r\n\r\n<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>".utf8)
        check(ConnectivityMath.classify(httpResponse: apple, connectMs: 12.345) == .ok(latencyMs: 12.3), "check: Apple's Success page → online, latency rounded")
        let portal = Data("HTTP/1.1 302 Found\r\nLocation: http://login.hotel.example/\r\n\r\n".utf8)
        let portal200 = Data("HTTP/1.1 200 OK\r\n\r\n<html>Please sign in</html>".utf8)
        check(ConnectivityMath.classify(httpResponse: portal, connectMs: 5) == .captivePortal
              && ConnectivityMath.classify(httpResponse: portal200, connectMs: 5) == .captivePortal, "check: redirect or other page → login page (captive portal)")
        check(ConnectivityMath.classify(httpResponse: nil, connectMs: nil) == .failed && ConnectivityMath.classify(httpResponse: Data("junk".utf8), connectMs: 3) == .failed
              && ConnectivityMath.classify(httpResponse: apple, connectMs: .nan) == .failed, "check: no answer or junk → no internet")

        check(ConnectivityMath.connectionLevel(connected: true, internet: "no_internet", latencyMs: nil) == .critical
              && ConnectivityMath.connectionLevel(connected: true, internet: "captive_portal", latencyMs: nil) == .warning
              && ConnectivityMath.connectionLevel(connected: true, internet: "ok", latencyMs: 600) == .warning
              && ConnectivityMath.connectionLevel(connected: true, internet: "ok", latencyMs: 20) == .normal
              && ConnectivityMath.connectionLevel(connected: false, internet: "not_checked", latencyMs: nil) == .normal,
              "connection level: no internet red, login page or ≥500 ms yellow, unplugged is not a fault")

        let both = [conn("ethernet", internet: "ok", primary: true, ms: 5), conn("wifi", internet: "ok", ms: 16)]
        check(ConnectivityMath.overall(both, checkEnabled: true) == ("ok", .normal), "overall: both online → ok")
        let lanDown = [conn("ethernet", internet: "no_internet", primary: true), conn("wifi", internet: "ok", ms: 16)]
        check(ConnectivityMath.overall(lanDown, checkEnabled: true) == ("degraded", .warning), "overall: main connection down, Wi-Fi up → degraded (yellow)")
        let wifiDown = [conn("ethernet", internet: "ok", primary: true, ms: 5), conn("wifi", internet: "no_internet")]
        check(ConnectivityMath.overall(wifiDown, checkEnabled: true) == ("ok", .warning) && wifiDown[1].level == "critical",
              "overall: spare Wi-Fi without internet → Mac yellow, that connection red")
        let none = [conn("ethernet", internet: "no_internet", primary: true), conn("wifi", internet: "no_internet")]
        check(ConnectivityMath.overall(none, checkEnabled: true) == ("offline", .critical), "overall: nothing reaches the internet → offline")
        let unplugged = [conn("ethernet", connected: false, internet: "not_checked"), conn("wifi", connected: false, internet: "not_checked")]
        check(ConnectivityMath.overall(unplugged, checkEnabled: true) == ("offline", .critical), "overall: no connection at all → offline")
        check(ConnectivityMath.overall(both.map { var c = $0; c.internet = "not_checked"; return c }, checkEnabled: false) == ("not_checked", .normal),
              "overall: check turned off → not checked, no colour")
        check(AppSettings.forTesting().internetCheck == false, "internet check is off by default (it contacts captive.apple.com)")
        let json = String(decoding: (try? StatusSnapshot.encoder().encode(InternetStatus(state: "ok", level: "normal", checkEnabled: true, connections: both))) ?? Data(), as: UTF8.self)
        check(json.contains("\"latency_ms\":5") && json.contains("\"is_primary\":true") && json.contains("\"check_enabled\":true"), "status JSON: internet section keys")
    }
}
