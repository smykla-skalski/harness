import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract regression for the websocket transport frame types generated
/// from src/daemon/protocol/websocket.rs. These *Wire types own the snake_case
/// shape (explicit CodingKeys, plain decoder) and prove the daemon's frames
/// decode: the request's serde_json::Value params (defaulting to JSONValue.null)
/// and trace_context dict, the response carrying a nested WsErrorPayloadWire, the
/// push event's JSONValue payload, and the chunk frame. The three config/probe/
/// inspect payloads are skipped until their persona/runtime/acp deps migrate.
/// Mapping these wire types to the app's unified WsFrame is a follow-up.
@Suite("WebSocket wire types decoding")
struct WebSocketWireTypesDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("decodes a request with its value params and trace context")
  func decodesRequest() throws {
    let json = #"""
      {"id":"req-1","method":"session.detail","params":{"session_id":"s-1"},"trace_context":{"traceparent":"abc"}}
      """#
    let request = try decoder.decode(WsRequestWire.self, from: Data(json.utf8))

    #expect(request.id == "req-1")
    #expect(request.method == "session.detail")
    #expect(request.params != JSONValue.null)
    #expect(request.traceContext?["traceparent"] == "abc")
  }

  @Test("defaults an omitted params to JSONValue.null")
  func decodesRequestDefaultingParams() throws {
    let json = #"{"id":"req-2","method":"stream.subscribe"}"#
    let request = try decoder.decode(WsRequestWire.self, from: Data(json.utf8))

    #expect(request.params == JSONValue.null)
    #expect(request.traceContext == nil)
  }

  @Test("decodes a response carrying a nested error payload")
  func decodesResponseWithError() throws {
    let json = #"""
      {"id":"req-3","error":{"code":"not_found","message":"missing","status_code":404},"batch_index":0,"batch_count":2}
      """#
    let response = try decoder.decode(WsResponseWire.self, from: Data(json.utf8))

    #expect(response.id == "req-3")
    #expect(response.result == nil)
    #expect(response.error?.code == "not_found")
    #expect(response.error?.statusCode == 404)
    #expect(response.error?.details.isEmpty == true)
    #expect(response.batchIndex == 0)
    #expect(response.batchCount == 2)
  }

  @Test("decodes a push event with its json payload and sequence")
  func decodesPushEvent() throws {
    let json = #"""
      {"event":"session.updated","recorded_at":"2026-06-15T00:00:00Z","session_id":"s-1","payload":{"status":"running"},"seq":42}
      """#
    let push = try decoder.decode(WsPushEventWire.self, from: Data(json.utf8))

    #expect(push.event == "session.updated")
    #expect(push.recordedAt == "2026-06-15T00:00:00Z")
    #expect(push.sessionId == "s-1")
    #expect(push.payload != JSONValue.null)
    #expect(push.seq == 42)
  }

  @Test("decodes a chunk frame from its snake_case keys")
  func decodesChunkFrame() throws {
    let json = #"""
      {"chunk_id":"c-1","chunk_index":1,"chunk_count":3,"chunk_base64":"YWJj"}
      """#
    let chunk = try decoder.decode(WsChunkFrameWire.self, from: Data(json.utf8))

    #expect(chunk.chunkId == "c-1")
    #expect(chunk.chunkIndex == 1)
    #expect(chunk.chunkCount == 3)
    #expect(chunk.chunkBase64 == "YWJj")
  }
}
