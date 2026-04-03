import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("WebSocket protocol wire format")
struct WebSocketProtocolTests {
  private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    return encoder
  }()

  private let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }()

  @Test("WsRequest encodes with snake_case keys")
  func requestEncoding() throws {
    let request = WsRequest(
      id: "abc-123",
      method: "session.detail",
      params: .object(["session_id": .string("sess-1")])
    )
    let data = try encoder.encode(request)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(json?["id"] as? String == "abc-123")
    #expect(json?["method"] as? String == "session.detail")
  }

  @Test("WsFrame decodes response with result")
  func responseDecoding() throws {
    let json = """
      {"id":"req-1","result":{"status":"ok"},"error":null}
      """
    let frame = try decoder.decode(WsFrame.self, from: Data(json.utf8))
    guard case .response(let id, let result, let error) = frame.kind else {
      Issue.record("Expected response frame kind, got \(frame.kind)")
      return
    }
    #expect(id == "req-1")
    #expect(result != nil)
    #expect(error == nil)
  }

  @Test("WsFrame decodes response with error")
  func errorDecoding() throws {
    let json = """
      {"id":"req-2","result":null,"error":{"code":"NOT_FOUND","message":"session not found","details":[]}}
      """
    let frame = try decoder.decode(WsFrame.self, from: Data(json.utf8))
    guard case .response(let id, _, let error) = frame.kind else {
      Issue.record("Expected response frame kind, got \(frame.kind)")
      return
    }
    #expect(id == "req-2")
    let resolvedError = try #require(error)
    #expect(resolvedError.code == "NOT_FOUND")
    #expect(resolvedError.message == "session not found")
  }

  @Test("WsFrame decodes push event")
  func pushEventDecoding() throws {
    let json = """
      {"event":"session_updated","recorded_at":"2026-03-29T12:00:00Z",\
      "session_id":"sess-1","payload":{},"seq":42}
      """
    let frame = try decoder.decode(WsFrame.self, from: Data(json.utf8))
    guard case .push(let event, _, let sessionId, _, let seq) = frame.kind else {
      Issue.record("Expected push frame kind, got \(frame.kind)")
      return
    }
    #expect(event == "session_updated")
    #expect(sessionId == "sess-1")
    #expect(seq == 42)
  }

  @Test("WsFrame returns unknown for empty object")
  func unknownFrame() throws {
    let json = "{}"
    let frame = try decoder.decode(WsFrame.self, from: Data(json.utf8))
    guard case .unknown = frame.kind else {
      Issue.record("Expected unknown frame kind, got \(frame.kind)")
      return
    }
  }

  @Test("PendingRequestStore resume delivers result")
  func pendingStoreResume() async throws {
    let store = PendingRequestStore()
    let result: JSONValue = try await withCheckedThrowingContinuation { continuation in
      store.register(id: "test-1", continuation: continuation)
      store.resume(id: "test-1", result: .string("hello"))
    }
    #expect(result == .string("hello"))
  }

  @Test("PendingRequestStore fail delivers error")
  func pendingStoreFail() async throws {
    let store = PendingRequestStore()
    await #expect(throws: WebSocketTransportError.self) {
      let _: JSONValue =
        try await withCheckedThrowingContinuation { continuation in
          store.register(id: "test-2", continuation: continuation)
          store.fail(
            id: "test-2",
            error: WebSocketTransportError.connectionClosed
          )
        }
    }
  }

  @Test("PendingRequestStore failAll clears all pending")
  func pendingStoreFailAll() async throws {
    let store = PendingRequestStore()
    await #expect(throws: WebSocketTransportError.self) {
      let _: JSONValue = try await withCheckedThrowingContinuation { continuation in
        store.register(id: "a", continuation: continuation)
        store.failAll(error: WebSocketTransportError.connectionClosed)
      }
    }
  }
}
