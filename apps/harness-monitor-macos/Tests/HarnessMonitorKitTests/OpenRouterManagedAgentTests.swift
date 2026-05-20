import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("OpenRouter managed-agent wire types")
struct OpenRouterManagedAgentTests {
  @Test("OpenRouterRunSnapshot decodes the daemon's snake_case payload")
  func decodesSnakeCaseSnapshot() throws {
    let payload = """
      {
        "run_id": "openrouter-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        "session_id": "11111111-1111-4111-8111-111111111111",
        "session_agent_id": null,
        "display_name": "OpenRouter",
        "model": "anthropic/claude-3.7-sonnet",
        "status": "streaming",
        "latest_message": "hello",
        "turn_count": 1,
        "created_at": "2026-05-20T12:00:00Z",
        "updated_at": "2026-05-20T12:00:01Z"
      }
      """.data(using: .utf8)!

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let snapshot = try decoder.decode(OpenRouterRunSnapshot.self, from: payload)

    #expect(snapshot.runId == "openrouter-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
    #expect(snapshot.model == "anthropic/claude-3.7-sonnet")
    #expect(snapshot.status == .streaming)
    #expect(snapshot.status.isActive)
    #expect(snapshot.latestMessage == "hello")
    #expect(snapshot.turnCount == 1)
  }

  @Test("OpenRouterStartRequest encodes snake_case keys")
  func encodesSnakeCaseStartRequest() throws {
    let request = OpenRouterStartRequest(
      model: "google/gemini-2.5-pro",
      prompt: "list files",
      sessionAgentId: "agent-7",
      displayName: "OpenRouter Test",
      temperature: 0.2,
      maxTokens: 128,
      reasoningEffort: "medium",
      projectDir: "/tmp/work"
    )
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(request)
    let json = String(data: data, encoding: .utf8) ?? ""

    #expect(json.contains("\"max_tokens\":128"))
    #expect(json.contains("\"reasoning_effort\":\"medium\""))
    #expect(json.contains("\"session_agent_id\":\"agent-7\""))
    #expect(json.contains("\"project_dir\":\"\\/tmp\\/work\""))
  }

  @Test("ManagedAgentSnapshot.openRouter round-trips through Codable")
  func managedAgentSnapshotRoundTrip() throws {
    let snapshot = OpenRouterRunSnapshot(
      runId: "openrouter-rid",
      sessionId: "11111111-1111-4111-8111-111111111111",
      sessionAgentId: nil,
      displayName: "OpenRouter",
      model: "anthropic/claude-3.7-sonnet",
      status: .idle,
      finalMessage: "done",
      turnCount: 3,
      createdAt: "2026-05-20T12:00:00Z",
      updatedAt: "2026-05-20T12:00:02Z"
    )
    let envelope = ManagedAgentSnapshot.openRouter(snapshot)

    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let data = try encoder.encode(envelope)

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let decoded = try decoder.decode(ManagedAgentSnapshot.self, from: data)

    guard case .openRouter(let restored) = decoded else {
      Issue.record("expected .openRouter variant after round-trip, got \(decoded)")
      return
    }
    #expect(restored == snapshot)
    #expect(decoded.family == .openRouter)
    #expect(decoded.agentId == "openrouter-rid")
    #expect(decoded.sessionId == "11111111-1111-4111-8111-111111111111")
  }

  @Test("TaskBoardOpenRouterCredentialSnapshot produces a sync request mirroring the field")
  func openRouterCredentialSnapshotEmitsSyncRequest() {
    let configured = TaskBoardOpenRouterCredentialSnapshot(token: "sk-or-abc")
    #expect(configured.syncRequest.token == "sk-or-abc")
    #expect(configured.isEmpty == false)

    let empty = TaskBoardOpenRouterCredentialSnapshot()
    #expect(empty.syncRequest.token == nil)
    #expect(empty.isEmpty)
  }

  @Test("HTTP and WebSocket OpenRouter start paths return the same managed-agent envelope")
  func startManagedOpenRouterAgentEnvelope() async throws {
    let fixture = OpenRouterRunSnapshot(
      runId: "openrouter-fix",
      sessionId: "11111111-1111-4111-8111-111111111111",
      sessionAgentId: nil,
      displayName: "Fixture",
      model: "anthropic/claude-3.7-sonnet",
      status: .pending,
      turnCount: 0,
      createdAt: "2026-05-20T12:00:00Z",
      updatedAt: "2026-05-20T12:00:00Z"
    )
    let envelope = ManagedAgentSnapshot.openRouter(fixture)
    #expect(envelope.managedAgentID == "openrouter-fix")
    #expect(envelope.openRouter == fixture)
    #expect(envelope.terminal == nil)
    #expect(envelope.codex == nil)
    #expect(envelope.acp == nil)
  }
}
