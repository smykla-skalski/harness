import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract regression for the session request protocol. The
/// SessionRequests*Wire types are generated from src/daemon/protocol/session_requests.rs
/// and own the snake_case wire shape (explicit CodingKeys); the rich app models
/// keep their ergonomic types (Int progress, `.locked` default, idiomatic
/// bookmarkID). The seven types with no Swift model are skipped by the generator.
/// This pins the model->wire encode keys, the Int->UInt8 progress conversion, the
/// internally-tagged drop target, and a response decode.
@Suite("Session requests wire types decoding")
struct SessionRequestsWireTypesDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("maps a task drop request to the wire type with snake_case keys and a tagged target")
  func mapsTaskDropRequestToWire() throws {
    let request = TaskDropRequest(
      actor: "leader",
      target: .agent(agentId: "worker-1"),
      queuePolicy: .locked,
      reason: "done"
    )
    let wire = TaskDropRequestWire(request)

    let object = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(wire)) as? [String: Any]
    )
    #expect(object["actor"] as? String == "leader")
    #expect(object["queue_policy"] != nil)
    #expect(object["reason"] as? String == "done")

    let target = try #require(object["target"] as? [String: Any])
    #expect(target["target_type"] as? String == "agent")
    #expect(target["agent_id"] as? String == "worker-1")
  }

  @Test("converts the Int progress app value to the wire u8")
  func convertsCheckpointProgress() throws {
    let request = TaskCheckpointRequest(actor: "worker", summary: "halfway", progress: 42)
    let wire = TaskCheckpointRequestWire(request)
    #expect(wire.progress == 42)

    let object = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(wire)) as? [String: Any]
    )
    #expect(object["progress"] as? Int == 42)
  }

  @Test("maps an adopt-session request to the wire type with snake_case keys")
  func mapsAdoptSessionToWire() throws {
    let request = AdoptSessionRequest(bookmarkID: "bm-1", sessionRoot: "/tmp/root")
    let wire = AdoptSessionRequestWire(request)

    let object = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(wire)) as? [String: Any]
    )
    #expect(object["bookmark_id"] as? String == "bm-1")
    #expect(object["session_root"] as? String == "/tmp/root")
  }

  @Test("decodes the archive response wire and maps it to the rich model")
  func decodesArchiveResponse() throws {
    let json = #"{"session_id":"session-1","archived_at":"2026-06-15T18:30:45Z"}"#
    let wire = try decoder.decode(SessionArchiveResponseWire.self, from: Data(json.utf8))
    let model = SessionArchiveResponse(wire: wire)

    #expect(model.sessionId == "session-1")
    #expect(model.archivedAt == "2026-06-15T18:30:45Z")
  }
}
