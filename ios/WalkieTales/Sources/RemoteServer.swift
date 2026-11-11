import Foundation
import Network
import UIKit

/// Tiny HTTP server on port 8480 for the remote (same API and PIN rules as the Android player).
/// Every /api/ request needs the PIN, as an "X-Pin" header or "?pin=" query parameter.
final class RemoteServer {
    static let port: UInt16 = 8480 // was 8080 before 1.45 (a port lots of other things use)
    /// The same remote over https (a home-made certificate), so the browser allows the microphone for voice messages.
    static let httpsPort: UInt16 = 8490
    static let maxUpload = 2_000_000_000

    struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
        var body: Data
    }

    /// Handles a JSON API call on the main thread. Return nil for "not found".
    var api: ((Request, [String: Any]) throws -> [String: Any]?)?

    private var listener: NWListener?
    private var secure: NWListener?
    private let queue = DispatchQueue(label: "remote-server")
    var isRunning: Bool { listener != nil }

    static var pin: String {
        #if targetEnvironment(simulator)
        if let t = ProcessInfo.processInfo.environment["WT_TEST_PIN"], !t.isEmpty { return t } // automated simulator test only
        #endif
        if let p = Store.ud.string(forKey: "remote_pin") { return p }
        return newPin()
    }

    @discardableResult
    static func newPin() -> String {
        let p = String(format: "%06d", Int.random(in: 0..<1_000_000))
        Store.set("remote_pin", p)
        return p
    }

    /// The phone's Wi-Fi address, e.g. http://192.168.1.50:8480
    static var address: String? { ip.map { "http://\($0):\(port)" } }

    /// The phone's Wi-Fi address, e.g. 192.168.1.50
    static var ip: String? {
        var addr: String?
        var ifa: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifa) == 0, let first = ifa else { return nil }
        defer { freeifaddrs(ifa) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let i = cur.pointee
            if i.ifa_addr.pointee.sa_family == UInt8(AF_INET), String(cString: i.ifa_name) == "en0" {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(i.ifa_addr, socklen_t(i.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                addr = String(cString: host)
            }
            p = i.ifa_next
        }
        return addr
    }

    func start() {
        guard listener == nil else { return }
        do {
            let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: RemoteServer.port)!)
            l.newConnectionHandler = { [weak self] c in self?.handle(c) }
            l.stateUpdateHandler = { [weak self] s in
                if case .failed = s { // port still busy (e.g. right after an update): try again shortly
                    self?.listener?.cancel(); self?.listener = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.start() }
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.start() }
        }
        startSecure()
    }

    /// https on 8490 with the player's own certificate (made once, off the main thread). Skipped if it can't be made.
    private func startSecure() {
        guard secure == nil else { return }
        let ip = RemoteServer.ip
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let id = SelfCert.identity(ip: ip), let sid = sec_identity_create(id) else { return }
            DispatchQueue.main.async {
                guard let self = self, self.listener != nil, self.secure == nil else { return }
                let tls = NWProtocolTLS.Options()
                sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sid)
                let params = NWParameters(tls: tls)
                params.allowLocalEndpointReuse = true
                guard let l = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: RemoteServer.httpsPort)!) else { return }
                l.newConnectionHandler = { [weak self] c in self?.handle(c) }
                l.stateUpdateHandler = { [weak self] s in
                    if case .failed = s { self?.secure?.cancel(); self?.secure = nil }
                }
                l.start(queue: self.queue)
                self.secure = l
            }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        secure?.cancel()
        secure = nil
    }

    // MARK: connection handling

    private func handle(_ c: NWConnection) {
        c.start(queue: queue)
        readHead(c, buffer: Data())
    }

    private func readHead(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self = self else { return }
            var buf = buffer
            if let d = data { buf.append(d) }
            if let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<r.lowerBound], as: UTF8.self)
                let rest = buf[r.upperBound...]
                self.parse(c, head: head, rest: Data(rest))
            } else if err != nil || done || buf.count > 64 * 1024 {
                c.cancel()
            } else {
                self.readHead(c, buffer: buf)
            }
        }
    }

    private func parse(_ c: NWConnection, head: String, rest: Data) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else { c.cancel(); return }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            if let i = l.firstIndex(of: ":") {
                headers[l[..<i].trimmingCharacters(in: .whitespaces).lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let comps = URLComponents(string: "http://x" + target)
        let path = comps?.path ?? target
        var query: [String: String] = [:]
        for q in comps?.queryItems ?? [] { query[q.name] = q.value ?? "" }
        let len = Int(headers["content-length"] ?? "0") ?? 0
        var req = Request(method: method, path: path, query: query, headers: headers, body: Data())

        if method == "OPTIONS" { send(c, 204, "text/plain", Data()); return }
        if method == "GET" && (path == "/" || path == "/index.html") {
            let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web")
                ?? Bundle.main.url(forResource: "index", withExtension: "html")
            let page = url.flatMap { try? Data(contentsOf: $0) }
            send(c, page == nil ? 404 : 200, "text/html; charset=utf-8", page ?? Data("Not found".utf8))
            return
        }
        guard path.hasPrefix("/api/") else { send(c, 404, "text/plain", Data("Not found".utf8)); return }
        let given = headers["x-pin"] ?? query["pin"] ?? ""
        let who: String = { if case let .hostPort(h, _) = c.endpoint { return "\(h)" }; return "?" }()
        let wait = Guard.blockedFor(who)
        if wait > 0 { // too many wrong PINs from here: make guessing all million PINs take months, not hours
            sendJson(c, 429, ["error": "Too many wrong PINs. Try again in \(max(1, Int(wait))) seconds"]); return
        }
        guard Data(given.trimmingCharacters(in: .whitespaces).utf8).elementsEqual(Data(RemoteServer.pin.utf8)) else {
            if !given.trimmingCharacters(in: .whitespaces).isEmpty { Guard.failed(who) } // no PIN at all isn't a guess
            sendJson(c, 401, ["error": "PIN required"]); return
        }
        Guard.ok(who)
        if method == "PUT" && path == "/api/upload" {
            upload(c, req: req, len: len, first: rest)
            return
        }
        if path == "/api/update" { // Android players update over Wi-Fi; an iPhone gets new versions through TrollStore
            sendJson(c, 400, ["error": "iPhone players are updated with TrollStore, not over Wi-Fi"])
            return
        }
        if method == "GET" && path == "/api/file" { // download one file (the remote's server converts what an iPhone can't play)
            guard let f = Store.safeName(query["folder"]), let n = Store.safeName(query["name"]),
                  let data = try? Data(contentsOf: Store.dir(f).appendingPathComponent(n), options: .mappedIfSafe) else {
                sendJson(c, 404, ["error": "No such file"]); return
            }
            send(c, 200, "application/octet-stream", data)
            return
        }
        if method == "GET" && path == "/api/cover" {
            // Library tiles ask for a small copy (w=360) with the folder's stamp (v): kept here and in the browser for a week.
            let size = Int(query["w"] ?? "").map { max(96, min(800, $0)) }
            let key = (size != nil && query["v"] != nil && query["now"] == nil) ? "\(query["folder"] ?? "")|\(query["v"]!)|\(size!)" : nil
            let cache = key != nil ? "private, max-age=604800, immutable" : "no-store"
            if let k = key, let kept = RemoteServer.thumbs.object(forKey: k as NSString) {
                send(c, kept.length == 0 ? 404 : 200, kept.length == 0 ? "text/plain" : "image/jpeg", kept as Data, cache: cache); return
            }
            DispatchQueue.main.async {
                let data = RemoteServer.cover(folder: query["folder"], now: query["now"] != nil, size: size)
                if let k = key { RemoteServer.thumbs.setObject((data ?? Data()) as NSData, forKey: k as NSString) }
                self.queue.async { self.send(c, data == nil ? 404 : 200, data == nil ? "text/plain" : "image/jpeg", data ?? Data(), cache: cache) }
            }
            return
        }
        guard len <= 1_000_000 else { sendJson(c, 413, ["error": "Too large"]); return }
        readBody(c, have: rest, need: len) { body in
            req.body = body
            let json = (try? JSONSerialization.jsonObject(with: body.isEmpty ? Data("{}".utf8) : body)) as? [String: Any] ?? [:]
            DispatchQueue.main.async {
                do {
                    if let out = try self.api?(req, json) {
                        self.queue.async { self.sendJson(c, 200, out) }
                    } else {
                        self.queue.async { self.sendJson(c, 404, ["error": "Not found"]) }
                    }
                } catch {
                    let msg = (error as? RemoteError)?.message ?? error.localizedDescription
                    self.queue.async { self.sendJson(c, 400, ["error": msg]) }
                }
            }
        }
    }

    private func readBody(_ c: NWConnection, have: Data, need: Int, done: @escaping (Data) -> Void) {
        if have.count >= need { done(have.prefix(need)); return }
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, fin, err in
            var b = have
            if let d = data { b.append(d) }
            if err != nil || (fin && b.count < need) { c.cancel(); return }
            self?.readBody(c, have: b, need: need, done: done)
        }
    }

    // MARK: uploads (streamed straight to disk)

    private func upload(_ c: NWConnection, req: Request, len: Int) {
        upload(c, req: req, len: len, first: Data())
    }

    private func upload(_ c: NWConnection, req: Request, len: Int, first: Data) {
        guard var folder = Store.safeName(req.query["folder"]), var name = Store.safeName(req.query["name"]) else {
            sendJson(c, 400, ["error": "Bad folder or file name"]); return
        }
        guard len > 0 else { sendJson(c, 411, ["error": "Content-Length required"]); return }
        guard len <= RemoteServer.maxUpload else { sendJson(c, 413, ["error": "File too large"]); return }
        // The iPhone's storage refuses characters newer than its iOS knows (e.g. 🪭 on iOS 15),
        // so if saving fails, try again with emoji taken out of the names.
        var d = Store.dir(folder), tmp = d
        func openPart() -> FileHandle? {
            d = Store.dir(folder)
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            tmp = d.appendingPathComponent("." + name + ".part")
            FileManager.default.createFile(atPath: tmp.path, contents: nil)
            return try? FileHandle(forWritingTo: tmp)
        }
        var handle = openPart()
        if handle == nil, let f2 = Store.safeName(Store.plainName(folder)), let n2 = Store.safeName(Store.plainName(name)),
           f2 != folder || n2 != name {
            folder = f2; name = n2; handle = openPart()
        }
        guard let fh = handle else { sendJson(c, 500, ["error": "Can't write"]); return }
        fh.write(first)
        var got = first.count
        func finish() {
            try? fh.close()
            let dest = d.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.moveItem(at: tmp, to: dest)
                if folder == Messages.folder { Messages.ensureCover() } // a voice message from the remote
                sendJson(c, 200, ["ok": true, "name": name])
                DispatchQueue.main.async { NotificationCenter.default.post(name: .libraryChanged, object: nil) }
            } catch {
                sendJson(c, 500, ["error": "Couldn't save the file"])
            }
        }
        func more() {
            if got >= len { finish(); return }
            c.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { data, _, fin, err in
                if let data = data, !data.isEmpty { fh.write(data); got += data.count }
                if got >= len { finish(); return }
                if err != nil || fin { try? fh.close(); try? FileManager.default.removeItem(at: tmp); c.cancel(); return }
                more()
            }
        }
        more()
    }

    // MARK: covers

    static let thumbs: NSCache<NSString, NSData> = { let c = NSCache<NSString, NSData>(); c.totalCostLimit = 6_000_000; return c }()

    static func cover(folder: String?, now: Bool, size: Int? = nil) -> Data? {
        guard let f = Store.safeName(folder) else { return nil }
        if now, Player.shared.folder == f, let t = Player.shared.current, !t.live, let img = Art.embedded(t.source) { return Art.jpeg(img) }
        guard let img = Art.folderCover(f, max: size.map { CGFloat($0) * 2 } ?? 900) else { return nil }
        guard let s = size else { return Art.jpeg(img) }
        // the shorter side at least `size` pixels, for the square tile
        let k = CGFloat(s) / min(img.size.width * img.scale, img.size.height * img.scale)
        if k >= 1 { return img.jpegData(compressionQuality: 0.8) }
        let out = CGSize(width: (img.size.width * img.scale * k).rounded(), height: (img.size.height * img.scale * k).rounded())
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        return UIGraphicsImageRenderer(size: out, format: fmt).image { _ in img.draw(in: CGRect(origin: .zero, size: out)) }.jpegData(compressionQuality: 0.8)
    }

    // MARK: responses

    private func sendJson(_ c: NWConnection, _ code: Int, _ obj: [String: Any]) {
        let d = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        send(c, code, "application/json; charset=utf-8", d)
    }

    private func send(_ c: NWConnection, _ code: Int, _ type: String, _ body: Data, cache: String = "no-store") {
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found",
                      411: "Length Required", 413: "Payload Too Large", 429: "Too Many Requests", 500: "Server Error"][code] ?? "OK"
        var head = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        // No cross-site access (the remote goes through its own server or this page), no framing, no sniffing.
        head += "Cache-Control: \(cache)\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nReferrer-Policy: no-referrer\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }
}

/// Wrong-PIN limit per address: 5 free tries, then a wait that doubles each time (30 s up to 1 hour). A right PIN clears it.
enum Guard {
    private static var fails: [String: (count: Int, until: Date)] = [:]
    private static let lock = NSLock()

    static func blockedFor(_ who: String) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        guard let f = fails[who] else { return 0 }
        return max(0, f.until.timeIntervalSinceNow)
    }

    static func failed(_ who: String) {
        lock.lock(); defer { lock.unlock() }
        var f = fails[who] ?? (0, Date.distantPast)
        f.count += 1
        if f.count >= 5 { f.until = Date().addingTimeInterval(min(3600, 30 * pow(2, Double(min(7, f.count - 5))))) }
        fails[who] = f
        if fails.count > 500 { fails.removeAll() } // never grows without bound
    }

    static func ok(_ who: String) {
        lock.lock(); defer { lock.unlock() }
        fails[who] = nil
    }
}

struct RemoteError: Error {
    let message: String
    init(_ m: String) { message = m }
}

extension Notification.Name {
    static let libraryChanged = Notification.Name("libraryChanged")
}
