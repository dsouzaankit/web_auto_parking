import Darwin
import Foundation
import Network
import UIKit

/// Serves app logs on Wi‑Fi (same pattern as Loop Segments LAN export — HTTP + Bonjour `_http._tcp`).
enum LANLogServer {
    static let defaultPort: UInt16 = 8765
    static let bonjourServiceName = "webautoparking"
    static let lanServerToggleTitle = "LAN logs on Wi‑Fi"

    private static let enabledKey = "serveLogsOnLAN"
    private static let lock = NSLock()
    private static var listener: NWListener?
    private static var listenerIsReady = false
    private static var startInFlight = false
    private static var connections: [ObjectIdentifier: NWConnection] = [:]
    private static let queue = DispatchQueue(label: "com.webautoparking.lan-log-server")
    private static var advertisedBaseURL: String?
    private static var advertisedIPAddressURL: String?

    static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: enabledKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var displayLANURLs: (host: String?, ip: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (advertisedBaseURL, advertisedIPAddressURL)
    }

    static var deviceMDNSHostName: String {
        "\(deviceMDNSHostLabel()).local"
    }

    static func ensureRunning() {
        guard isEnabled else { return }
        lock.lock()
        let running = listenerIsReady && listener != nil
        lock.unlock()
        if !running {
            start()
        }
    }

    static func applyEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled {
            start()
        } else {
            stop()
        }
    }

    static func start() {
        guard isEnabled else { return }
        lock.lock()
        if listenerIsReady, listener != nil {
            lock.unlock()
            return
        }
        if startInFlight {
            lock.unlock()
            return
        }
        startInFlight = true
        lock.unlock()

        queue.async {
            defer {
                lock.lock()
                startInFlight = false
                lock.unlock()
            }
            beginListen()
        }
    }

    static func stop() {
        queue.async {
            stopOnQueue()
        }
    }

    private static func beginListen() {
        guard isEnabled else { return }

        lock.lock()
        if listenerIsReady, listener != nil {
            lock.unlock()
            return
        }
        let stale = listener
        listener = nil
        listenerIsReady = false
        lock.unlock()
        stale?.cancel()

        do {
            let port = NWEndpoint.Port(rawValue: defaultPort)!
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let nwListener = try NWListener(using: params, on: port)
            let ipForTXT = primaryLANIPv4Address()
            var txtRecord: Data?
            if let ipForTXT, !ipForTXT.isEmpty {
                txtRecord = NetService.data(fromTXTRecord: ["ip": Data(ipForTXT.utf8)])
            }
            nwListener.service = NWListener.Service(
                name: bonjourServiceName,
                type: "_http._tcp",
                txtRecord: txtRecord
            )

            lock.lock()
            listener = nwListener
            lock.unlock()

            nwListener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let ip = primaryLANIPv4Address()
                    let hostURL = "http://\(deviceMDNSHostName):\(defaultPort)/"
                    let ipURL = ip.map { "http://\($0):\(defaultPort)/" }
                    lock.lock()
                    listenerIsReady = true
                    advertisedBaseURL = hostURL
                    advertisedIPAddressURL = ipURL
                    lock.unlock()
                    AppLog.log(
                        "LAN logs: \(hostURL)\(ip.map { " · IP \($0)" } ?? "") — Bonjour \(bonjourServiceName)._http._tcp"
                    )
                    AppLog.log("LAN: Windows often cannot resolve .local — prefer the IP URL")
                case .failed(let error):
                    AppLog.log("LAN log server failed: \(error.localizedDescription)")
                    stopOnQueue()
                case .cancelled:
                    lock.lock()
                    listenerIsReady = false
                    lock.unlock()
                default:
                    break
                }
            }

            nwListener.newConnectionHandler = { connection in
                connection.start(queue: queue)
                let id = ObjectIdentifier(connection)
                lock.lock()
                connections[id] = connection
                lock.unlock()
                receiveRequest(on: connection) { [id] in
                    lock.lock()
                    connections.removeValue(forKey: id)
                    lock.unlock()
                }
            }

            nwListener.start(queue: queue)
        } catch {
            AppLog.log("LAN log server could not start: \(error.localizedDescription)")
        }
    }

    private static func stopOnQueue() {
        lock.lock()
        let active = listener
        listener = nil
        listenerIsReady = false
        advertisedBaseURL = nil
        advertisedIPAddressURL = nil
        let open = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        open.forEach { $0.cancel() }
        active?.cancel()
        AppLog.log("LAN log server stopped")
    }

    // MARK: - HTTP

    private static func receiveRequest(on connection: NWConnection, done: @escaping () -> Void) {
        receiveHTTPHeaders(on: connection, accumulated: Data(), done: done)
    }

    private static func receiveHTTPHeaders(
        on connection: NWConnection,
        accumulated: Data,
        done: @escaping () -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
            if error != nil {
                connection.cancel()
                done()
                return
            }
            guard let data, !data.isEmpty else {
                sendResponse(connection: connection, status: 400, contentType: "text/plain", body: Data("Bad request".utf8), done: done)
                return
            }
            var buffer = accumulated
            buffer.append(data)
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > 64 * 1024 {
                    sendResponse(connection: connection, status: 413, contentType: "text/plain", body: Data("Request too large".utf8), done: done)
                    return
                }
                receiveHTTPHeaders(on: connection, accumulated: buffer, done: done)
                return
            }
            let headerData = buffer[..<headerEnd.lowerBound]
            guard let text = String(data: headerData, encoding: .utf8),
                  let line = text.split(separator: "\r\n", maxSplits: 1).first,
                  let (method, path) = parseRequestLine(String(line)) else {
                sendResponse(connection: connection, status: 400, contentType: "text/plain", body: Data("Bad request".utf8), done: done)
                return
            }
            handleGET(method: method, path: path, connection: connection, done: done)
        }
    }

    private static func parseRequestLine(_ line: String) -> (String, String)? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        var path = String(parts[1])
        if let q = path.firstIndex(of: "?") {
            path = String(path[..<q])
        }
        path = path.removingPercentEncoding ?? path
        if path.isEmpty { path = "/" }
        return (method, path)
    }

    private static func handleGET(
        method: String,
        path: String,
        connection: NWConnection,
        done: @escaping () -> Void
    ) {
        switch method {
        case "GET", "HEAD":
            break
        case "OPTIONS":
            sendResponse(
                connection: connection,
                status: 204,
                contentType: "text/plain",
                body: Data(),
                extraHeaders: ["Allow: GET, HEAD, OPTIONS"],
                done: done
            )
            return
        default:
            sendResponse(connection: connection, status: 405, contentType: "text/plain", body: Data("Allowed: GET, HEAD, OPTIONS".utf8), done: done)
            return
        }

        let normalized = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        switch normalized {
        case "/", "":
            let html = indexHTML()
            let body = method == "HEAD" ? Data() : Data(html.utf8)
            sendResponse(connection: connection, status: 200, contentType: "text/html; charset=utf-8", body: body, done: done)
        case "/logs.txt", "/latest.txt", "/logs/latest.txt":
            let text = AppLog.readAllText()
            let body = method == "HEAD" ? Data() : Data(text.utf8)
            sendResponse(connection: connection, status: 200, contentType: "text/plain; charset=utf-8", body: body, done: done)
        default:
            sendResponse(connection: connection, status: 404, contentType: "text/plain", body: Data("Not found".utf8), done: done)
        }
    }

    private static func indexHTML() -> String {
        let urls = displayLANURLs
        let ipLine = urls.ip.map { htmlEscape($0) } ?? "(no IPv4 yet)"
        let hostLine = urls.host.map { htmlEscape($0) } ?? "(starting…)"
        let log = htmlEscape(AppLog.readAllText())
        return """
        <!DOCTYPE html>
        <html lang="en"><head>
        <meta charset="utf-8"/>
        <meta name="viewport" content="width=device-width, initial-scale=1"/>
        <title>Parking — LAN logs</title>
        <style>
          body { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; margin: 1.25rem; background: #111; color: #e8e8e8; }
          a { color: #8ec8ff; }
          .muted { color: #9a9a9a; }
          pre { white-space: pre-wrap; word-break: break-word; background: #1a1a1a; padding: 1rem; border-radius: 8px; max-height: 70vh; overflow: auto; }
          h1 { font-size: 1.15rem; font-weight: 600; }
        </style>
        <meta http-equiv="refresh" content="5"/>
        </head><body>
        <h1>Parking — LAN logs</h1>
        <p class="muted">Port \(defaultPort) · auto-refresh 5s · plain text: <a href="/logs.txt">/logs.txt</a></p>
        <p>IP: <code>\(ipLine)</code><br/>mDNS: <code>\(hostLine)</code></p>
        <pre id="log">\(log)</pre>
        </body></html>
        """
    }

    private static func htmlEscape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func sendResponse(
        connection: NWConnection,
        status: Int,
        contentType: String,
        body: Data,
        extraHeaders: [String] = [],
        done: @escaping () -> Void
    ) {
        let phrase: String
        switch status {
        case 200: phrase = "OK"
        case 204: phrase = "No Content"
        case 400: phrase = "Bad Request"
        case 404: phrase = "Not Found"
        case 405: phrase = "Method Not Allowed"
        case 413: phrase = "Payload Too Large"
        default: phrase = "Error"
        }
        var header = "HTTP/1.1 \(status) \(phrase)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n"
        header += "Cache-Control: no-store\r\n"
        for line in extraHeaders {
            header += "\(line)\r\n"
        }
        header += "\r\n"
        var data = Data(header.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
            done()
        })
    }

    // MARK: - Network helpers

    private static func deviceMDNSHostLabel() -> String {
        let deviceName = UIDevice.current.name
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if !deviceName.isEmpty {
            return sanitizeMDNSHostLabel(deviceName)
        }
        var buffer = [CChar](repeating: 0, count: 256)
        if gethostname(&buffer, buffer.count) == 0 {
            let host = String(cString: buffer)
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if !host.isEmpty, host != "localhost" {
                let base = host.hasSuffix(".local") ? String(host.dropLast(6)) : host
                return sanitizeMDNSHostLabel(base)
            }
        }
        return "iphone"
    }

    private static func sanitizeMDNSHostLabel(_ label: String) -> String {
        let folded = label.folding(options: .diacriticInsensitive, locale: .current)
        let safe = folded.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "'", with: "")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return safe.isEmpty ? "iphone" : safe
    }

    private static func primaryLANIPv4Address() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var candidates: [(name: String, address: String)] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let family = interface.ifa_addr.pointee.sa_family
            guard family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            guard name == "en0" || name.hasPrefix("en") else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                interface.ifa_addr,
                socklen_t(interface.ifa_addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let ip = String(cString: hostname)
            if ip.hasPrefix("127.") || ip.hasPrefix("169.254.") || ip == "0.0.0.0" { continue }
            candidates.append((name, ip))
        }
        if let en0 = candidates.first(where: { $0.name == "en0" })?.address {
            return en0
        }
        return candidates.first?.address
    }
}
