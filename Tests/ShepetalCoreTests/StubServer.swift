import Foundation
import Network

/// A local HTTP stub of the account service on 127.0.0.1. Each request goes to `handler`, which returns a
/// status and a JSON body; status 0 drops the connection without an answer (offline). Never the real network.
final class StubServer: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: [String: Any]
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "account-stub")
    private let lock = NSLock()
    private var log: [Request] = []
    private var _handler: (Request) -> (Int, Any)
    private(set) var port: UInt16 = 0

    var requests: [Request] { lock.withLock { log } }
    var handler: (Request) -> (Int, Any) {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue } }
    }
    var url: URL { URL(string: "http://127.0.0.1:\(port)")! }

    init(handler: @escaping (Request) -> (Int, Any) = { _ in (404, [:]) }) throws {
        _handler = handler
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] c in self?.serve(c) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    deinit { listener.cancel() }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, Data())
    }

    private func receive(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if done || error != nil { c.cancel() } else { self.receive(c, buffer) }
                return
            }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            var headers: [String: String] = [:]
            for line in head.dropFirst() {
                if let i = line.firstIndex(of: ":") {
                    headers[line[..<i].lowercased()] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
                }
            }
            let length = Int(headers["content-length"] ?? "0") ?? 0
            let body = buffer[end.upperBound...]
            guard body.count >= length else { return self.receive(c, buffer) }
            let parts = head[0].split(separator: " ")
            let request = Request(method: String(parts[0]), path: String(parts[1]), headers: headers,
                                  body: (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any] ?? [:])
            self.lock.withLock { self.log.append(request) }
            let (status, json) = self.handler(request)
            guard status != 0 else { return c.cancel() }
            let payload = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
            var out = Data("HTTP/1.1 \(status) Stub\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n".utf8)
            out.append(payload)
            c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
        }
    }
}
