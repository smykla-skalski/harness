import Foundation
import Synchronization

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

final class PendingRequestStore: Sendable {
  private let storage = Mutex<[String: CheckedContinuation<JSONValue, any Error>]>([:])

  func register(id: String, continuation: CheckedContinuation<JSONValue, any Error>) {
    storage.withLock { $0[id] = continuation }
  }

  func resume(id: String, result: JSONValue) {
    let continuation = storage.withLock { $0.removeValue(forKey: id) }
    continuation?.resume(returning: result)
  }

  func fail(id: String, error: any Error) {
    let continuation = storage.withLock { $0.removeValue(forKey: id) }
    continuation?.resume(throwing: error)
  }

  func failAll(error: any Error) {
    let pending = storage.withLock {
      let all = $0
      $0.removeAll()
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
