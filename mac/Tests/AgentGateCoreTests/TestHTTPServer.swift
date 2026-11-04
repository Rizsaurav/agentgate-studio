import Foundation
import Network

/// A minimal HTTP/1.1 file server on 127.0.0.1 with Range support, for downloader tests.
/// `cutAfter` closes the first response after that many body bytes, like a dropped connection.
final class TestHTTPServer: @unchecked Sendable {
  let body: Data
  private let listener: NWListener
  private let queue = DispatchQueue(label: "test-http")
  private let lock = NSLock()
  private var cutAfter: Int?
  private(set) var rangeHeaders: [String] = []
  var port: UInt16 { listener.port?.rawValue ?? 0 }

  init(body: Data, cutAfter: Int? = nil) throws {
    self.body = body
    self.cutAfter = cutAfter
    let params = NWParameters.tcp
    params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
    listener = try NWListener(using: params)
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
    listener.newConnectionHandler = { [weak self] in self?.serve($0) }
    listener.start(queue: queue)
    _ = ready.wait(timeout: .now() + 5)
  }

  func url(_ path: String = "/model.gguf") -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

  func stop() { listener.cancel() }

  private func serve(_ connection: NWConnection) {
    connection.start(queue: queue)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, _, _ in
      let request = String(decoding: data ?? Data(), as: UTF8.self)
      let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
      guard path == "/model.gguf" else {
        send(connection, head: "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n", body: Data())
        return
      }
      var start = 0
      if let line = request.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("range:") }) {
        lock.withLock { rangeHeaders.append(String(line)) }
        start = Int(line.split(separator: "=").last?.split(separator: "-").first ?? "0") ?? 0
      }
      let slice = body.subdata(in: start..<body.count)
      let status = start > 0 ? "206 Partial Content" : "200 OK"
      var head = "HTTP/1.1 \(status)\r\nContent-Length: \(slice.count)\r\nConnection: close\r\n"
      if start > 0 { head += "Content-Range: bytes \(start)-\(body.count - 1)/\(body.count)\r\n" }
      head += "\r\n"
      let cut = lock.withLock { () -> Int? in defer { cutAfter = nil }; return cutAfter }
      send(connection, head: head, body: cut.map { slice.prefix($0) } ?? slice)
    }
  }

  private func send(_ connection: NWConnection, head: String, body: Data) {
    connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
  }
}
