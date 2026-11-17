import Foundation
import Network

/// Where a model id goes: the local engine, or a cloud provider with the user's key.
public enum ModelRoute: Sendable, Equatable {
  case local(baseURL: URL, key: String, model: String)
  case cloud(Provider, model: String)
}

/// How the gateway names models: a catalog id ("qwen3-1.7b") is local; "<provider>/<model>" is that
/// provider's model ("openai/gpt-4.1-mini", "openrouter/deepseek/deepseek-chat"). Catalog ids never contain "/".
public enum ModelID {
  public static func cloud(_ provider: Provider, _ model: String) -> String { "\(provider.id)/\(model)" }

  /// The provider and its own model id, or nil for a local id.
  public static func parseCloud(_ id: String) -> (Provider, String)? {
    guard let slash = id.firstIndex(of: "/") else { return nil }
    let providerID = String(id[..<slash])
    let model = String(id[id.index(after: slash)...])
    guard !model.isEmpty, let provider = Providers.all.first(where: { $0.id == providerID }) else { return nil }
    return (provider, model)
  }

  public static func isCloud(_ id: String) -> Bool { parseCloud(id) != nil }
}

/// One OpenAI-compatible endpoint on 127.0.0.1 for every model, local or cloud (#71). The harness, the
/// evaluation runner and anything else talk only to this, so they treat every model the same way.
///
/// - Requests need the per-launch key; nothing else on the Mac can use it.
/// - Bodies stream through unchanged (tool calls included); only the model id is rewritten.
/// - A client that goes away cancels the upstream request.
/// - Provider keys are read from the Keychain per request, sent only to that provider, and never logged
///   or returned. Provider errors come back as one plain sentence, never the provider's own body.
public final class Gateway: @unchecked Sendable {
  public typealias Resolve = @Sendable (String) -> ModelRoute?
  public typealias ProviderKey = @Sendable (Provider) -> String?

  public let key: String
  public var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

  private let listener: NWListener
  private let queue = DispatchQueue(label: "agentgate.gateway")
  private let resolve: Resolve
  private let providerKey: ProviderKey
  private let lock = NSLock()
  private var forwards: [UUID: Task<Void, Never>] = [:]

  /// Requests being forwarded now; for tests and the status bar.
  public var activeForwards: Int { lock.withLock { forwards.count } }
  public var port: UInt16 { listener.port?.rawValue ?? 0 }

  static let maxBody = 32 << 20

  public init(resolve: @escaping Resolve, providerKey: @escaping ProviderKey = Gateway.keychainKey) throws {
    self.resolve = resolve
    self.providerKey = providerKey
    key = UUID().uuidString + UUID().uuidString
    let params = NWParameters.tcp
    params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
    listener = try NWListener(using: params)
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
    listener.newConnectionHandler = { [weak self] in self?.accept($0) }
    listener.start(queue: queue)
    guard ready.wait(timeout: .now() + 5) == .success else { throw RuntimeError.noFreePort }
  }

  /// A key that cannot be read is treated like a missing one: the request is refused with "add a key",
  /// which is the user's way out either way. Nothing about the key is logged.
  public static let keychainKey: ProviderKey = { provider in try? provider.keychain.read() }

  public func stop() {
    listener.cancel()
    lock.withLock { forwards.values.forEach { $0.cancel() }; forwards = [:] }
  }

  deinit { stop() }

  // MARK: Requests

  struct Request {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
  }

  private func accept(_ connection: NWConnection) {
    connection.start(queue: queue)
    read(connection, buffer: Data())
  }

  /// Reads until the head and the whole body (by Content-Length) have arrived.
  private func read(_ connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
      guard let self else { return }
      var buffer = buffer
      if let data { buffer.append(data) }
      switch Self.parse(buffer) {
      case .needMore where !complete && error == nil && buffer.count <= Self.maxBody:
        self.read(connection, buffer: buffer)
      case .request(let request):
        self.handle(request, on: connection)
      default:
        self.respond(connection, status: 400, message: "The request could not be read.")
      }
    }
  }

  enum Parsed {
    case needMore
    case invalid
    case request(Request)
  }

  static func parse(_ data: Data) -> Parsed {
    guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return data.count > 64 << 10 ? .invalid : .needMore }
    let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).split(separator: "\r\n", omittingEmptySubsequences: false)
    let line = head.first?.split(separator: " ") ?? []
    guard line.count >= 2 else { return .invalid }
    var headers: [String: String] = [:]
    for field in head.dropFirst() {
      guard let colon = field.firstIndex(of: ":") else { continue }
      headers[field[..<colon].lowercased()] = field[field.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    let length = Int(headers["content-length"] ?? "0") ?? -1
    guard length >= 0, length <= maxBody else { return .invalid }
    let body = data[end.upperBound...]
    guard body.count >= length else { return .needMore }
    return .request(Request(method: String(line[0]), path: String(line[1]), headers: headers, body: Data(body.prefix(length))))
  }

  private func handle(_ request: Request, on connection: NWConnection) {
    // Constant-time comparison of the per-launch key.
    let given = Array((request.headers["authorization"] ?? "").utf8)
    let wanted = Array("Bearer \(key)".utf8)
    guard given.count == wanted.count, zip(given, wanted).reduce(0, { $0 | ($1.0 ^ $1.1) }) == 0 else {
      return respond(connection, status: 401, message: "Missing or wrong gateway key.")
    }
    switch (request.method, request.path.split(separator: "?").first.map(String.init) ?? "") {
    case ("GET", "/health"):
      respond(connection, status: 200, json: ["status": "ok"])
    case ("POST", "/v1/chat/completions"):
      forward(request, on: connection)
    default:
      respond(connection, status: 404, message: "Only /v1/chat/completions is served here.")
    }
  }

  private func forward(_ request: Request, on connection: NWConnection) {
    guard var body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
          let id = body["model"] as? String else {
      return respond(connection, status: 400, message: "The request body must be JSON with a model.")
    }
    guard let route = resolve(id) else {
      return respond(connection, status: 404, message: "The model \(id) is not available. Load it, or add a key for its provider.")
    }
    let upstream: URLRequest
    let label: String
    switch route {
    case .local(let base, let localKey, let model):
      body["model"] = model
      upstream = Self.upstream(base.appendingPathComponent("v1/chat/completions"), key: localKey, body: body)
      label = "the local engine"
    case .cloud(let provider, let model):
      guard let secret = providerKey(provider), !secret.isEmpty else {
        return respond(connection, status: 401, message: "There is no \(provider.name) key. Add one on the Profile page.")
      }
      body["model"] = model
      // Options only the local engine understands are not sent to providers.
      body["chat_template_kwargs"] = nil
      body["cache_prompt"] = nil
      upstream = Self.upstream(URL(string: provider.baseURL)!.appendingPathComponent("chat/completions"), key: secret, body: body)
      label = provider.name
    }
    let token = UUID()
    let task = Task { [weak self] in
      await self?.stream(upstream, label: label, to: connection)
      self?.lock.withLock { _ = self?.forwards.removeValue(forKey: token) }
    }
    lock.withLock { forwards[token] = task }
    // The client hung up: stop the upstream request too. A closed socket is only noticed while reading,
    // so a read stays open for the whole response; it ends with the connection.
    connection.stateUpdateHandler = { state in
      switch state {
      case .failed, .cancelled: task.cancel()
      default: break
      }
    }
    watchHangUp(connection, task)
  }

  private func watchHangUp(_ connection: NWConnection, _ task: Task<Void, Never>) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, complete, error in
      if complete || error != nil { task.cancel() } else { self?.watchHangUp(connection, task) }
    }
  }

  static func upstream(_ url: URL, key: String, body: [String: Any]) -> URLRequest {
    // Long prompts on a CPU can take many minutes before the first byte; clients set their own limits.
    var request = URLRequest(url: url, timeoutInterval: 1800)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    return request
  }

  private func stream(_ request: URLRequest, label: String, to connection: NWConnection) async {
    let upstream = UpstreamStream(request)
    do {
      var sentHead = false
      for try await event in upstream.events {
        switch event {
        case .response(let status, let contentType):
          if status == 401 || status == 403 {
            upstream.cancel()
            return respond(connection, status: status, message: "\(label) rejected the key. It may be wrong or revoked: check it on the Profile page.")
          }
          if status >= 400 {
            upstream.cancel()
            return respond(connection, status: status == 429 ? 429 : 502, message: "\(label) answered with an error (HTTP \(status)).")
          }
          let head = "HTTP/1.1 \(status) OK\r\nContent-Type: \(contentType)\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
          try await send(connection, Data(head.utf8))
          sentHead = true
        case .data(let chunk):
          if sentHead { try await send(connection, chunk) }
        }
      }
      connection.cancel()
    } catch {
      upstream.cancel()
      if Task.isCancelled { connection.cancel(); return }
      respond(connection, status: 502, message: "\(label) could not be reached.")
    }
  }

  private func send(_ connection: NWConnection, _ data: Data) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      connection.send(content: data, completion: .contentProcessed { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      })
    }
  }

  private func respond(_ connection: NWConnection, status: Int, message: String) {
    respond(connection, status: status, json: ["error": ["message": message, "type": "agentgate_gateway"]])
  }

  private func respond(_ connection: NWConnection, status: Int, json: [String: Any]) {
    let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    let head = "HTTP/1.1 \(status) \(status < 400 ? "OK" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
    connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
  }
}

/// One upstream request whose response arrives as it is received: the status first, then chunks.
final class UpstreamStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  enum Event {
    case response(status: Int, contentType: String)
    case data(Data)
  }

  let events: AsyncThrowingStream<Event, Error>
  private let continuation: AsyncThrowingStream<Event, Error>.Continuation
  private var session: URLSession?
  private var task: URLSessionDataTask?

  init(_ request: URLRequest) {
    (events, continuation) = AsyncThrowingStream<Event, Error>.makeStream(bufferingPolicy: .unbounded)
    super.init()
    let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    self.session = session
    task = session.dataTask(with: request)
    continuation.onTermination = { [weak self] _ in self?.cancel() }
    task?.resume()
  }

  func cancel() {
    task?.cancel()
    session?.invalidateAndCancel()
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                  completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    let http = response as? HTTPURLResponse
    continuation.yield(.response(status: http?.statusCode ?? 0,
                                 contentType: http?.value(forHTTPHeaderField: "Content-Type") ?? "application/json"))
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    continuation.yield(.data(data))
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error { continuation.finish(throwing: error) } else { continuation.finish() }
    session.finishTasksAndInvalidate()
  }
}
