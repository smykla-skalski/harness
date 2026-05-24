import Foundation
import HarnessMonitorCore
import HarnessMonitorCrypto
import Network

public enum MobilePairingHTTPServerError: Error, Equatable, Sendable {
  case alreadyRunning
  case notRunning
  case listenerFailed(String)
  case listenerMissingPort
  case noPendingInvitation
  case invalidRequest
  case unsupportedRequest(String)
}

public final class MobilePairingHTTPServer: @unchecked Sendable {
  private let acceptor: MobilePairingStationAcceptor
  private let host: String
  private let queue: DispatchQueue
  private let now: @Sendable () -> Date
  private let onPairAccepted: @Sendable () async -> Void
  private let lock = NSLock()
  private var listener: NWListener?
  private var pendingNonce: String?

  public init(
    stationIdentity: MobilePairingStationIdentity,
    trustStore: any MobilePairingTrustedDeviceStore,
    host: String = "127.0.0.1",
    now: @escaping @Sendable () -> Date = Date.init,
    onPairAccepted: @escaping @Sendable () async -> Void = {}
  ) {
    acceptor = MobilePairingStationAcceptor(
      identity: stationIdentity,
      trustStore: trustStore
    )
    self.host = host
    self.now = now
    self.onPairAccepted = onPairAccepted
    queue = DispatchQueue(
      label: "io.harnessmonitor.mobile-pairing-http.\(stationIdentity.stationID)"
    )
  }

  public func start(
    port: UInt16 = 0,
    invitationTTL: TimeInterval = 300
  ) async throws -> MobilePairingInvitation {
    guard !hasActiveListener() else {
      throw MobilePairingHTTPServerError.alreadyRunning
    }

    let requestedPort = NWEndpoint.Port(rawValue: port) ?? .any
    let listener = try NWListener(using: .tcp, on: requestedPort)
    let readyState = MobilePairingListenerReadyState()
    listener.newConnectionHandler = { [weak self] connection in
      self?.handle(connection)
    }
    listener.stateUpdateHandler = { state in
      switch state {
      case .ready:
        Task { await readyState.ready() }
      case .failed(let error):
        Task {
          await readyState.fail(
            MobilePairingHTTPServerError.listenerFailed(String(describing: error))
          )
        }
      case .cancelled:
        Task {
          await readyState.fail(MobilePairingHTTPServerError.listenerFailed("cancelled"))
        }
      default:
        break
      }
    }

    setListener(listener)
    listener.start(queue: queue)
    do {
      try await readyState.wait()
    } catch {
      stop()
      throw error
    }
    guard let actualPort = listener.port?.rawValue else {
      stop()
      throw MobilePairingHTTPServerError.listenerMissingPort
    }
    return try makeInvitation(port: actualPort, invitationTTL: invitationTTL)
  }

  public func renewInvitation(
    invitationTTL: TimeInterval = 300
  ) async throws -> MobilePairingInvitation {
    guard let actualPort = activePort() else {
      throw MobilePairingHTTPServerError.notRunning
    }
    return try makeInvitation(port: actualPort, invitationTTL: invitationTTL)
  }

  private func makeInvitation(
    port: UInt16,
    invitationTTL: TimeInterval
  ) throws -> MobilePairingInvitation {
    let endpoint = try endpointURL(port: port)
    let nonce = UUID().uuidString
    setPendingNonce(nonce)
    return try acceptor.makeInvitation(
      endpoint: endpoint,
      nonce: nonce,
      expiresAt: now().addingTimeInterval(invitationTTL)
    )
  }

  public func stop() {
    lock.lock()
    let activeListener = listener
    listener = nil
    pendingNonce = nil
    lock.unlock()
    activeListener?.cancel()
  }

  private func endpointURL(port: UInt16) throws -> URL {
    var components = URLComponents()
    components.scheme = "http"
    components.host = host
    components.port = Int(port)
    components.path = "/pair"
    guard let url = components.url else {
      throw MobilePairingHTTPServerError.invalidRequest
    }
    return url
  }

  private func handle(_ connection: NWConnection) {
    let state = MobilePairingConnectionState()
    connection.stateUpdateHandler = { [weak self, state] connectionState in
      guard let self else {
        connection.cancel()
        return
      }
      switch connectionState {
      case .ready:
        guard state.markReady() else {
          return
        }
        self.receive(from: connection, buffer: Data())
      case .failed, .cancelled:
        connection.cancel()
      default:
        break
      }
    }
    connection.start(queue: queue)
  }

  private func hasActiveListener() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return listener != nil
  }

  private func activePort() -> UInt16? {
    lock.lock()
    defer { lock.unlock() }
    return listener?.port?.rawValue
  }

  private func setListener(_ listener: NWListener?) {
    lock.lock()
    self.listener = listener
    lock.unlock()
  }

  private func setPendingNonce(_ nonce: String?) {
    lock.lock()
    pendingNonce = nonce
    lock.unlock()
  }

  private func receive(from connection: NWConnection, buffer: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
      [weak self] data, _, _, error in
      guard let self else {
        connection.cancel()
        return
      }
      if error != nil {
        connection.cancel()
        return
      }
      var nextBuffer = buffer
      if let data {
        nextBuffer.append(data)
      }
      do {
        guard let request = try Self.parseRequest(nextBuffer) else {
          self.receive(from: connection, buffer: nextBuffer)
          return
        }
        Task {
          do {
            let responseBody = try await self.responseBody(for: request)
            self.send(responseBody, statusCode: 200, to: connection)
          } catch {
            self.sendError(error, to: connection)
          }
        }
      } catch {
        self.sendError(error, to: connection)
      }
    }
  }

  private func responseBody(for request: ParsedHTTPRequest) async throws -> Data {
    guard request.method == "POST", request.path == "/pair" else {
      throw MobilePairingHTTPServerError.unsupportedRequest("\(request.method) \(request.path)")
    }
    guard let nonce = currentPendingNonce() else {
      throw MobilePairingHTTPServerError.noPendingInvitation
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let pairingRequest = try decoder.decode(MobilePairingRequest.self, from: request.body)
    let response = try await acceptor.accept(
      pairingRequest,
      expectedNonce: nonce,
      now: now()
    )
    clearPendingNonce(matching: nonce)
    await onPairAccepted()
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(response)
  }

  private func send(_ body: Data, statusCode: Int, to connection: NWConnection) {
    let reason = statusCode == 200 ? "OK" : "Bad Request"
    let header =
      "HTTP/1.1 \(statusCode) \(reason)\r\n"
      + "Content-Type: application/json\r\n"
      + "Content-Length: \(body.count)\r\n"
      + "Connection: close\r\n\r\n"
    var response = Data(header.utf8)
    response.append(body)
    connection.send(
      content: response,
      completion: .contentProcessed { _ in
        connection.cancel()
      })
  }

  private func sendError(_ error: Error, to connection: NWConnection) {
    let payload = "{\"error\":\"\(Self.escape(String(describing: error)))\"}"
    send(Data(payload.utf8), statusCode: 400, to: connection)
  }

  private func currentPendingNonce() -> String? {
    lock.lock()
    defer { lock.unlock() }
    return pendingNonce
  }

  private func clearPendingNonce(matching nonce: String) {
    lock.lock()
    if pendingNonce == nonce {
      pendingNonce = nil
    }
    lock.unlock()
  }

  private static func parseRequest(_ data: Data) throws -> ParsedHTTPRequest? {
    let delimiter = Data("\r\n\r\n".utf8)
    guard let delimiterRange = data.range(of: delimiter) else {
      return nil
    }
    guard let headerText = String(data: data[..<delimiterRange.lowerBound], encoding: .utf8)
    else {
      throw MobilePairingHTTPServerError.invalidRequest
    }
    var lines = headerText.components(separatedBy: "\r\n")
    guard !lines.isEmpty else {
      throw MobilePairingHTTPServerError.invalidRequest
    }
    let requestLine = lines.removeFirst().split(separator: " ")
    guard requestLine.count >= 2 else {
      throw MobilePairingHTTPServerError.invalidRequest
    }
    let contentLength = lines.reduce(0) { partial, line in
      let parts = line.split(separator: ":", maxSplits: 1).map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      guard parts.count == 2, parts[0].caseInsensitiveCompare("Content-Length") == .orderedSame
      else {
        return partial
      }
      return Int(parts[1]) ?? partial
    }
    let bodyStart = delimiterRange.upperBound
    guard data.count >= bodyStart + contentLength else {
      return nil
    }
    let body = data[bodyStart..<bodyStart + contentLength]
    return ParsedHTTPRequest(
      method: String(requestLine[0]),
      path: String(requestLine[1]),
      body: Data(body)
    )
  }

  private static func escape(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
  }
}

private struct ParsedHTTPRequest: Sendable {
  var method: String
  var path: String
  var body: Data
}

private final class MobilePairingConnectionState: @unchecked Sendable {
  private let lock = NSLock()
  private var isReady = false

  func markReady() -> Bool {
    lock.withLock {
      guard !isReady else {
        return false
      }
      isReady = true
      return true
    }
  }
}

private actor MobilePairingListenerReadyState {
  private var isReady = false
  private var failure: MobilePairingHTTPServerError?
  private var continuation: CheckedContinuation<Void, Error>?

  func wait() async throws {
    if isReady {
      return
    }
    if let failure {
      throw failure
    }
    try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
    }
  }

  func ready() {
    guard !isReady else {
      return
    }
    isReady = true
    continuation?.resume()
    continuation = nil
  }

  func fail(_ error: MobilePairingHTTPServerError) {
    guard !isReady else {
      return
    }
    failure = error
    continuation?.resume(throwing: error)
    continuation = nil
  }
}
