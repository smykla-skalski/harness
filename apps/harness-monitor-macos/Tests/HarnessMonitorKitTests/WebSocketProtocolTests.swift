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
    guard case .response(let id, let result, let error, let batchIndex, let batchCount) = frame.kind
    else {
      Issue.record("Expected response frame kind, got \(frame.kind)")
      return
    }
    #expect(id == "req-1")
    #expect(result != nil)
    #expect(error == nil)
    #expect(batchIndex == nil)
    #expect(batchCount == nil)
  }

  @Test("WsFrame decodes response with error")
  func errorDecoding() throws {
    let json = """
      {"id":"req-2","result":null,"error":{"code":"NOT_FOUND","message":"session not found","details":[]}}
      """
    let frame = try decoder.decode(WsFrame.self, from: Data(json.utf8))
    guard case .response(let id, _, let error, let batchIndex, let batchCount) = frame.kind else {
      Issue.record("Expected response frame kind, got \(frame.kind)")
      return
    }
    #expect(id == "req-2")
    let resolvedError = try #require(error)
    #expect(resolvedError.code == "NOT_FOUND")
    #expect(resolvedError.message == "session not found")
    #expect(batchIndex == nil)
    #expect(batchCount == nil)
  }

  @Test("WsFrame decodes semantic response batch metadata")
  func responseBatchDecoding() throws {
    let json = """
      {
        "id":"req-batch",
        "batch_index":1,
        "batch_count":3,
        "result":[{"entry_id":"entry-1","summary":"hello"}]
      }
      """
    let frame = try decoder.decode(WsFrame.self, from: Data(json.utf8))
    guard case .response(let id, let result, let error, let batchIndex, let batchCount) = frame.kind
    else {
      Issue.record("Expected response batch frame kind, got \(frame.kind)")
      return
    }

    #expect(id == "req-batch")
    #expect(error == nil)
    #expect(batchIndex == 1)
    #expect(batchCount == 3)
    guard let resolvedResult = result else {
      Issue.record("Expected response batch array payload, got nil")
      return
    }
    guard case .array(let entries) = resolvedResult else {
      Issue.record("Expected response batch array payload, got \(String(describing: result))")
      return
    }
    #expect(entries.count == 1)
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

  @Test("WsFrame decodes chunk frame metadata")
  func chunkFrameDecoding() throws {
    let json = """
      {
        "chunk_id":"response:req-1",
        "chunk_index":0,
        "chunk_count":2,
        "chunk_base64":"e30="
      }
      """
    let frame = try decoder.decode(WsFrame.self, from: Data(json.utf8))
    guard case .chunk(let chunkID, let chunkIndex, let chunkCount, let chunkBase64) = frame.kind
    else {
      Issue.record("Expected chunk frame kind, got \(frame.kind)")
      return
    }

    #expect(chunkID == "response:req-1")
    #expect(chunkIndex == 0)
    #expect(chunkCount == 2)
    #expect(chunkBase64 == "e30=")
  }

  @Test("SessionUpdatedPayload decodes when timeline is omitted")
  func sessionUpdatedPayloadWithoutTimeline() throws {
    let json = """
      {
        "detail": {
          "session": {
            "project_id": "project-1",
            "project_name": "Harness",
            "project_dir": "/tmp/harness",
            "context_root": "/tmp/context",
            "session_id": "sess-1",
            "context": "Demo session",
            "status": "active",
            "created_at": "2026-03-29T12:00:00Z",
            "updated_at": "2026-03-29T12:00:00Z",
            "last_activity_at": "2026-03-29T12:00:00Z",
            "leader_id": "leader-1",
            "observe_id": null,
            "pending_leader_transfer": null,
            "metrics": {
              "agent_count": 1,
              "active_agent_count": 1,
              "open_task_count": 0,
              "in_progress_task_count": 0,
              "blocked_task_count": 0,
              "completed_task_count": 0
            }
          },
          "agents": [],
          "tasks": [],
          "signals": [],
          "observer": null,
          "agent_activity": []
        }
      }
      """
    let payload = try decoder.decode(SessionUpdatedPayload.self, from: Data(json.utf8))

    #expect(payload.detail.session.sessionId == "sess-1")
    #expect(payload.timeline == nil)
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

  @Test("PendingRequestStore assembles semantic response batches")
  func pendingStoreResumeBatch() async throws {
    let store = PendingRequestStore()
    let result: JSONValue = try await withCheckedThrowingContinuation { continuation in
      store.register(id: "batched", continuation: continuation)
      _ = try? store.resumeBatch(
        id: "batched",
        index: 1,
        count: 2,
        result: .array([.string("beta")])
      )
      _ = try? store.resumeBatch(
        id: "batched",
        index: 0,
        count: 2,
        result: .array([.string("alpha")])
      )
    }

    #expect(result == .array([.string("alpha"), .string("beta")]))
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
