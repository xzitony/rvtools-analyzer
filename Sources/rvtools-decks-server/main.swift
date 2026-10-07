import Foundation
import Network
import RVToolsCore

// rvtools-decks-server --recipe <file.rvadecks> [--port 8080] [--passcode <code> | --no-passcode] [--local-only]
//                      [--solutions <dir>] [--max-mb 500]
// Serves a page where people upload an RVTools export and download the recipe's decks as a .zip. Everything runs on this
// Mac: uploads go to a temporary folder that's deleted as soon as the zip is sent, and nothing is kept or logged but a line
// per request.

var args = Array(CommandLine.arguments.dropFirst())
func value(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}
func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}
func log(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    print("[\(f.string(from: Date()))] \(s)"); fflush(stdout)
}

guard let recipePath = value("--recipe") else {
    print("usage: rvtools-decks-server --recipe <file.rvadecks> [--port 8080] [--passcode <code> | --no-passcode] [--local-only] [--solutions <dir>] [--max-mb 500]")
    exit(1)
}
let port = value("--port").flatMap(UInt16.init) ?? 8080
let maxBytes = (value("--max-mb").flatMap(Int.init) ?? 500) * 1_048_576
var solutionDirs: [URL] = []
while let d = value("--solutions") { solutionDirs.append(URL(fileURLWithPath: d)) }
let localOnly = flag("--local-only")
let passcode: String? = flag("--no-passcode") ? nil : (value("--passcode") ?? String((0..<6).map { _ in "ABCDEFGHJKLMNPQRSTUVWXYZ23456789".randomElement()! }))

SolutionLibrary.shared.extraDirectories = solutionDirs
SolutionLibrary.shared.reload()
for issue in SolutionLibrary.shared.issues { log("! \(issue.path): \(issue.message)") }

let recipe: DeckRecipe
do { recipe = try DeckRecipe.load(URL(fileURLWithPath: recipePath)) } catch {
    print("Could not read \(recipePath): \(error.localizedDescription)"); exit(1)
}
let problems = recipe.problems()
guard problems.isEmpty else { problems.forEach { print("✗ " + $0) }; exit(1) }

struct DeckInfo: Encodable { var id: String; var name: String }
struct Config: Encodable { var title: String; var decks: [DeckInfo]; var passcode: Bool; var maxMB: Int }
let config = Config(title: recipe.title ?? "RVTools decks",
                    decks: recipe.decks.map { DeckInfo(id: $0.solution, name: $0.name ?? SolutionCatalog.solution(id: $0.solution)?.title ?? $0.solution) },
                    passcode: passcode != nil, maxMB: maxBytes / 1_048_576)

// MARK: - HTTP

struct Request {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
}

struct Response: Error {
    var status: Int
    var type: String
    var body: Data
    var headers: [String: String] = [:]

    static func text(_ status: Int, _ s: String) -> Response { Response(status: status, type: "text/plain; charset=utf-8", body: Data(s.utf8)) }
    static func json<T: Encodable>(_ v: T) -> Response { Response(status: 200, type: "application/json", body: (try? JSONEncoder().encode(v)) ?? Data()) }

    func serialized() -> Data {
        let reasons = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large", 500: "Internal Server Error"]
        var head = "HTTP/1.1 \(status) \(reasons[status] ?? "Status")\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            + "Connection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        return Data((head + "\r\n").utf8) + body
    }
}

/// Reads one request (headers, then Content-Length bytes) from a connection.
final class Reader {
    let connection: NWConnection
    var buffer = Data()
    var headerEnd: Int?
    var head: (method: String, path: String, headers: [String: String])?
    let done: (Result<Request, Response>) -> Void

    init(_ connection: NWConnection, done: @escaping (Result<Request, Response>) -> Void) { self.connection = connection; self.done = done }

    func start() { receive() }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, complete, error in
            if let data { buffer.append(data) }
            if let error { log("connection error: \(error)"); connection.cancel(); return }
            if headerEnd == nil, let r = buffer.range(of: Data("\r\n\r\n".utf8)) {
                headerEnd = r.upperBound
                guard let text = String(data: buffer[..<r.lowerBound], encoding: .utf8) else { return done(.failure(.text(400, "Bad request"))) }
                var lines = text.components(separatedBy: "\r\n")
                let first = lines.removeFirst().split(separator: " ").map(String.init)
                guard first.count >= 2 else { return done(.failure(.text(400, "Bad request"))) }
                var headers: [String: String] = [:]
                for l in lines { if let c = l.firstIndex(of: ":") { headers[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces) } }
                head = (first[0], first[1], headers)
            } else if headerEnd == nil, buffer.count > 64 * 1024 {
                return done(.failure(.text(400, "Headers too large")))
            }
            if let end = headerEnd, let head {
                let length = Int(head.headers["content-length"] ?? "0") ?? 0
                if length > maxBytes { return done(.failure(.text(413, "That upload is over the \(maxBytes / 1_048_576) MB limit."))) }
                if buffer.count - end >= length {
                    return done(.success(Request(method: head.method, path: head.path, headers: head.headers, body: buffer.subdata(in: end..<(end + length)))))
                }
            }
            if complete { connection.cancel(); return }
            receive()
        }
    }
}

/// Uploads arrive as repeated [UInt32 name length][name][UInt32 size][bytes], all big-endian, so several exports
/// (one per vCenter) fit in one request without multipart parsing.
func unpackFiles(_ body: Data) -> [(name: String, data: Data)]? {
    var out: [(String, Data)] = []
    var i = body.startIndex
    func u32() -> Int? {
        guard body.endIndex - i >= 4 else { return nil }
        defer { i += 4 }
        return body[i..<(i + 4)].reduce(0) { $0 << 8 | Int($1) }
    }
    while i < body.endIndex {
        guard let n = u32(), body.endIndex - i >= n, let name = String(data: body[i..<(i + n)], encoding: .utf8) else { return nil }
        i += n
        guard let size = u32(), body.endIndex - i >= size else { return nil }
        out.append((name, body.subdata(in: i..<(i + size))))
        i += size
    }
    return out
}

struct DeckResult: Encodable { var name: String; var file: String; var ok: Bool; var error: String? }

/// One upload at a time: decks are quick, and it keeps memory flat when big exports arrive together.
let work = DispatchQueue(label: "decks")

func handle(_ req: Request, from peer: String) -> Response {
    let path = req.path.split(separator: "?").first.map(String.init) ?? "/"
    switch (req.method, path) {
    case ("GET", "/"): return Response(status: 200, type: "text/html; charset=utf-8", body: Data(page.utf8))
    case ("GET", "/config"): return .json(config)
    case ("POST", "/decks"): break
    case (_, "/"), (_, "/config"), (_, "/decks"): return .text(405, "Method not allowed")
    default: return .text(404, "Not found")
    }
    if let code = passcode, (req.headers["x-passcode"] ?? "").uppercased() != code {
        log("\(peer) wrong passcode")
        return .text(401, "That passcode isn't right.")
    }
    guard let files = unpackFiles(req.body), !files.isEmpty else { return .text(400, "No export was uploaded.") }
    let customer = (req.headers["x-customer"]?.removingPercentEncoding ?? "").trimmingCharacters(in: .whitespaces)
    let only = req.headers["x-decks"].map { Set($0.split(separator: ",").map(String.init)) }

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rvtools-decks-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var inputs: [URL] = []
        for (n, f) in files.enumerated() {
            let base = DeckBatch.safeFileName((f.name as NSString).lastPathComponent)
            guard base.lowercased().hasSuffix(".xlsx") else { return .text(400, "“\(f.name)” isn't an RVTools .xlsx export.") }
            let url = dir.appendingPathComponent("\(n)-" + base)
            try f.data.write(to: url)
            inputs.append(url)
        }
        let started = Date()
        let outputs = try DeckBatch.run(recipe, inputs: inputs, customer: customer, only: only)
        let results = outputs.map { DeckResult(name: $0.name, file: $0.fileName, ok: $0.data != nil, error: $0.error) }
        log("\(peer) \(files.map(\.name).joined(separator: ", ")) (\(files.reduce(0) { $0 + $1.data.count } / 1024) KB)"
            + (customer.isEmpty ? "" : " for “\(customer)”") + " → " + results.map { ($0.ok ? "✓ " : "✗ ") + $0.name }.joined(separator: ", ")
            + String(format: " in %.1f s", Date().timeIntervalSince(started)))
        let summary = String(data: (try? JSONEncoder().encode(results)) ?? Data(), encoding: .utf8)?
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        guard outputs.contains(where: { $0.data != nil }) else {
            return Response(status: 500, type: "text/plain; charset=utf-8", body: Data("No deck could be made.".utf8), headers: ["X-Deck-Results": summary])
        }
        let first = (files[0].name as NSString).deletingPathExtension
        let zipName = (customer.isEmpty ? first : DeckBatch.safeFileName(customer)) + " decks.zip"
        return Response(status: 200, type: "application/zip", body: DeckBatch.zip(outputs), headers: [
            "Content-Disposition": "attachment; filename=\"decks.zip\"; filename*=UTF-8''" + (zipName.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "decks.zip"),
            "X-Deck-Results": summary,
        ])
    } catch {
        log("\(peer) \(files.map(\.name).joined(separator: ", ")) failed: \(error.localizedDescription)")
        return .text(400, "Couldn't read that export: \(error.localizedDescription)")
    }
}

// MARK: - Listener

let params = NWParameters.tcp
if localOnly { params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!) }
let listener: NWListener
do { listener = try localOnly ? NWListener(using: params) : NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!) } catch {
    print("Could not listen on port \(port): \(error)"); exit(1)
}
listener.newConnectionHandler = { connection in
    let peer: String = { if case let .hostPort(host, _) = connection.endpoint { return "\(host)" }; return "?" }()
    connection.start(queue: work)
    Reader(connection) { result in
        let response: Response
        switch result {
        case .success(let req): response = handle(req, from: peer)
        case .failure(let r): response = r
        }
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in connection.cancel() })
    }.start()
}
listener.stateUpdateHandler = { state in
    switch state {
    case .ready:
        print("RVTools decks — \(config.title): " + config.decks.map(\.name).joined(separator: ", "))
        print("  http://localhost:\(port)")
        if !localOnly { for ip in localAddresses() { print("  http://\(ip):\(port)") } }
        print(passcode.map { "  Passcode: \($0)" } ?? "  No passcode: anyone who can reach this Mac can use it.")
        print("Uploads are deleted as soon as the decks are sent. Ctrl-C stops the server.")
        fflush(stdout)
    case .failed(let error):
        print("Server stopped: \(error)"); exit(1)
    default: break
    }
}
listener.start(queue: .main)

/// This Mac's IPv4 addresses, to tell people where to point their browser.
func localAddresses() -> [String] {
    var out: [String] = []
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
    defer { freeifaddrs(ifaddr) }
    for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let flags = Int32(p.pointee.ifa_flags)
        guard let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET), flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { out.append(String(cString: host)) }
    }
    return out
}

dispatchMain()
