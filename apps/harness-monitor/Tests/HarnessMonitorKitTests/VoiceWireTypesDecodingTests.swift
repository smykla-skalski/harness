import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract regression for the voice session protocol. The voice wire
/// types are generated from src/daemon/protocol/voice.rs: the enums carry
/// `rename_all = "camelCase"` (so sink/route values are camelCase strings),
/// while the structs use default snake_case field keys. Both transports decode
/// the responses through the plain `PolicyWireCoding.decoder`.
@Suite("Voice wire types decoding")
struct VoiceWireTypesDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("session start response decodes camelCase sink values")
  func decodesStartResponse() throws {
    let json = #"""
      {"voice_session_id":"vs-1","accepted_sinks":["localDaemon","agentBridge"],"status":"accepted"}
      """#
    let response = try decoder.decode(VoiceSessionStartResponse.self, from: Data(json.utf8))
    #expect(response.voiceSessionId == "vs-1")
    #expect(response.acceptedSinks == [.localDaemon, .agentBridge])
    #expect(response.status == "accepted")
  }

  @Test("transcript segment decodes snake_case fields")
  func decodesTranscriptSegment() throws {
    let json = #"""
      {"sequence":3,"text":"hello","is_final":true,"started_at_seconds":1.5,"duration_seconds":0.5,"confidence":0.9}
      """#
    let segment = try decoder.decode(VoiceTranscriptSegment.self, from: Data(json.utf8))
    #expect(segment.sequence == 3)
    #expect(segment.text == "hello")
    #expect(segment.isFinal == true)
    #expect(segment.startedAtSeconds == 1.5)
    #expect(segment.confidence == 0.9)
  }

  @Test("route target decodes a camelCase kind with omitted optionals")
  func decodesRouteTarget() throws {
    let target = try decoder.decode(
      VoiceRouteTarget.self,
      from: Data(#"{"kind":"codexPrompt"}"#.utf8)
    )
    #expect(target.kind == .codexPrompt)
    #expect(target.runId == nil)
    #expect(target.command == nil)
  }
}
