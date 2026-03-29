import Foundation

struct WsRequest: Codable, Sendable {
  let id: String
  let method: String
  let params: JSONValue?
}

struct WsFrame: Codable, Sendable {
  let id: String?
  let result: JSONValue?
  let error: WsErrorPayload?
  let event: String?
  let recordedAt: String?
  let sessionId: String?
  let payload: JSONValue?
  let seq: UInt64?
}

struct WsErrorPayload: Codable, Sendable {
  let code: String
  let message: String
  let details: [String]?
}

enum WsFrameKind {
  case response(id: String, result: JSONValue?, error: WsErrorPayload?)
  case push(event: String, recordedAt: String, sessionId: String?, payload: JSONValue, seq: UInt64)
  case unknown
}

extension WsFrame {
  var kind: WsFrameKind {
    let hasResponseFields = result != nil || error != nil
    if let id, hasResponseFields {
      return .response(id: id, result: result, error: error)
    }
    if let event, let recordedAt, let payload {
      return .push(
        event: event,
        recordedAt: recordedAt,
        sessionId: sessionId,
        payload: payload,
        seq: seq ?? 0
      )
    }
    return .unknown
  }
}

final class PendingRequestStore: @unchecked Sendable {
  private var continuations: [String: CheckedContinuation<JSONValue, any Error>] = [:]
  private let lock = NSLock()

  func register(id: String, continuation: CheckedContinuation<JSONValue, any Error>) {
    lock.withLock { continuations[id] = continuation }
  }

  func resume(id: String, result: JSONValue) {
    let continuation = lock.withLock { continuations.removeValue(forKey: id) }
    continuation?.resume(returning: result)
  }

  func fail(id: String, error: any Error) {
    let continuation = lock.withLock { continuations.removeValue(forKey: id) }
    continuation?.resume(throwing: error)
  }

  func failAll(error: any Error) {
    let pending = lock.withLock {
      let all = continuations
      continuations.removeAll()
      return all
    }
    for (_, continuation) in pending {
      continuation.resume(throwing: error)
    }
  }
}

enum WebSocketTransportError: LocalizedError {
  case serverError(code: String, message: String)
  case connectionClosed
  case upgradeRejected
  case unexpectedResponse

  var errorDescription: String? {
    switch self {
    case .serverError(_, let message): message
    case .connectionClosed: "WebSocket connection closed"
    case .upgradeRejected: "WebSocket upgrade rejected by server"
    case .unexpectedResponse: "Unexpected response from server"
    }
  }
}
