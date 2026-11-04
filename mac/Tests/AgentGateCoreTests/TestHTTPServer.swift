import Foundation
import Network

/// A minimal HTTP/1.1 file server on 127.0.0.1 with Range support, for downloader tests.
/// It can misbehave on purpose, like a flaky network or a bad mirror.
final class TestHTTPServer: @unchecked Sendable {
  enum Fault: Sendable {
    /// Serves the file normally.
    case none
    /// Closes the first response after this many body bytes, like a dropped connection.
    case cutFirst(after: Int)
    /// Closes every response after this many body bytes.
    case cutAlways(after: Int)
    /// Sends this many body bytes on the first response, then goes silent without closing.
    case stallFirst(after: Int)
    /// Ignores Range headers and always answers 200 with the whole file.
    case ignoreRange
    /// Cuts the first response, then ignores Range headers: a mirror that cannot resume.
    case cutFirstThenIgnoreRange(after: Int)
    /// Answers every request with this error status and no body.
    case answer(status: Int)
  }

  let body: Data
  /// The only path answered; anything else gets 404.
  let servedPath: String
  private let listener: NWListener
  private let queue = DispatchQueue(label: "test-http")
  private let lock = NSLock()
  private var fault: Fault
  private var firstConsumed = false
  private(set) var rangeHeaders: [String] = []
  private(set) var requestCount = 0
  private var held: [NWConnection] = []
  var port: UInt16 { listener.port?.rawValue ?? 0 }

  init(body: Data, cutAfter: Int? = nil, fault: Fault? = nil, servedPath: String = "/model.gguf") throws {
    self.body = body
    self.servedPath = servedPath
    self.fault = fault ?? cutAfter.map { .cutFirst(after: $0) } ?? .none
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

  func stop() {
    listener.cancel()
    lock.withLock { held.forEach { $0.cancel() }; held = [] }
  }

  private func serve(_ connection: NWConnection) {
    connection.start(queue: queue)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, _, _ in
      let request = String(decoding: data ?? Data(), as: UTF8.self)
      let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
      lock.withLock { requestCount += 1 }
      guard path == servedPath else {
        send(connection, head: "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n", body: Data())
        return
      }
      let (current, isFirst): (Fault, Bool) = lock.withLock {
        defer { firstConsumed = true }
        return (fault, !firstConsumed)
      }
      if case .answer(let status) = current {
        send(connection, head: "HTTP/1.1 \(status) Error\r\nContent-Length: 0\r\n\r\n", body: Data())
        return
      }
      var start = 0
      if let line = request.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("range:") }) {
        lock.withLock { rangeHeaders.append(String(line)) }
        switch current {
        case .ignoreRange, .cutFirstThenIgnoreRange: break
        default: start = Int(line.split(separator: "=").last?.split(separator: "-").first ?? "0") ?? 0
        }
      }
      let slice = body.subdata(in: start..<body.count)
      let status = start > 0 ? "206 Partial Content" : "200 OK"
      var head = "HTTP/1.1 \(status)\r\nContent-Length: \(slice.count)\r\nConnection: close\r\n"
      if start > 0 { head += "Content-Range: bytes \(start)-\(body.count - 1)/\(body.count)\r\n" }
      head += "\r\n"
      switch current {
      case .cutFirst(let n) where isFirst, .cutFirstThenIgnoreRange(let n) where isFirst:
        send(connection, head: head, body: slice.prefix(n))
      case .cutAlways(let n): send(connection, head: head, body: slice.prefix(n))
      case .stallFirst(let n) where isFirst:
        // Send a prefix and keep the connection open without sending more.
        lock.withLock { held.append(connection) }
        connection.send(content: Data(head.utf8) + slice.prefix(n), completion: .contentProcessed { _ in })
      default: send(connection, head: head, body: slice)
      }
    }
  }

  private func send(_ connection: NWConnection, head: String, body: Data) {
    connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
  }
}
