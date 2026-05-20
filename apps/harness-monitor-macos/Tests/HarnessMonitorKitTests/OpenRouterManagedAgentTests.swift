import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("OpenRouter ACP transport projection")
struct OpenRouterManagedAgentTests {
  private static let fixedSessionID = "11111111-1111-4111-8111-111111111111"
  private static let fixedRunID = "openrouter-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

  private static func fixtureAcpSnapshot(status: AgentStatus = .active) -> AcpAgentSnapshot {
    AcpAgentSnapshot(
      acpId: fixedRunID,
      sessionId: fixedSessionID,
      agentId: "session-agent-7",
      displayName: "OpenRouter",
      status: status,
      pid: 1234,
      pgid: 4321,
      projectDir: "/tmp/work",
      pendingPermissions: 0,
      permissionQueueDepth: 0,
      pendingPermissionBatches: [],
      terminalCount: 0,
      createdAt: "2026-05-20T12:00:00Z",
      updatedAt: "2026-05-20T12:00:01Z"
    )
  }

  @Test("OpenRouterRunSnapshot projects ACP snapshot fields and carries supplied model")
  func projectsAcpFields() {
    let acp = Self.fixtureAcpSnapshot()
    let run = OpenRouterRunSnapshot(
      acp: acp,
      model: "anthropic/claude-3.7-sonnet",
      displayName: "OpenRouter Test",
      latestMessage: "hello",
      turnCount: 1
    )
    #expect(run.runId == Self.fixedRunID)
    #expect(run.sessionId == Self.fixedSessionID)
    #expect(run.sessionAgentId == "session-agent-7")
    #expect(run.displayName == "OpenRouter Test")
    #expect(run.model == "anthropic/claude-3.7-sonnet")
    #expect(run.status == .streaming)
    #expect(run.latestMessage == "hello")
    #expect(run.turnCount == 1)
    #expect(run.createdAt == "2026-05-20T12:00:00Z")
    #expect(run.updatedAt == "2026-05-20T12:00:01Z")
  }

  @Test("OpenRouterRunStatus maps ACP lifecycle states")
  func mapsAcpStatuses() {
    #expect(
      OpenRouterRunStatus(acp: .active, disconnect: nil) == .streaming
    )
    #expect(
      OpenRouterRunStatus(acp: .idle, disconnect: nil) == .idle
    )
    #expect(
      OpenRouterRunStatus(
        acp: .disconnected,
        disconnect: AgentDisconnectReason(kind: "user_cancelled", code: nil, signal: nil)
      ) == .cancelled
    )
    #expect(
      OpenRouterRunStatus(
        acp: .disconnected,
        disconnect: AgentDisconnectReason(kind: "process_exited", code: 1, signal: nil)
      ) == .failed
    )
    #expect(
      OpenRouterRunStatus(acp: .removed, disconnect: nil) == .cancelled
    )
  }

  @Test("OpenRouterRunStatus.isActive matches streaming and pending")
  func statusActiveness() {
    #expect(OpenRouterRunStatus.streaming.isActive)
    #expect(OpenRouterRunStatus.pending.isActive)
    #expect(!OpenRouterRunStatus.idle.isActive)
    #expect(!OpenRouterRunStatus.cancelled.isActive)
    #expect(!OpenRouterRunStatus.failed.isActive)
  }

  @Test("OpenRouter dispatch uses the openrouter ACP descriptor id")
  func dispatchDescriptorIdIsStable() {
    #expect(OpenRouterAcpDispatch.descriptorID == "openrouter")
    #expect(OpenRouterAcpDispatch.defaultModel == "anthropic/claude-3.7-sonnet")
  }

  @Test("Permission batches stay carried across the ACP projection")
  func permissionBatchesCarry() {
    let batch = AcpPermissionBatch(
      batchId: "batch-or-1",
      acpId: Self.fixedRunID,
      sessionId: Self.fixedSessionID,
      requests: [],
      createdAt: "2026-05-20T00:00:00Z",
      expiresAt: "2026-05-20T00:05:00Z"
    )
    var acp = Self.fixtureAcpSnapshot()
    acp = AcpAgentSnapshot(
      acpId: acp.acpId,
      sessionId: acp.sessionId,
      agentId: acp.agentId,
      displayName: acp.displayName,
      status: acp.status,
      pid: acp.pid,
      pgid: acp.pgid,
      projectDir: acp.projectDir,
      pendingPermissions: 1,
      permissionQueueDepth: 1,
      pendingPermissionBatches: [batch],
      terminalCount: acp.terminalCount,
      createdAt: acp.createdAt,
      updatedAt: acp.updatedAt
    )
    let run = OpenRouterRunSnapshot(acp: acp, model: "anthropic/claude-3.7-sonnet")
    #expect(run.pendingPermissionBatches.count == 1)
    #expect(run.pendingPermissionBatches.first?.batchId == "batch-or-1")
  }

  @Test("OpenRouterModelEntry decodes context_length and supported_parameters")
  func openRouterModelEntryDecodes() throws {
    let payload = """
      {
        "id": "anthropic/claude-3.7-sonnet",
        "name": "Claude 3.7 Sonnet",
        "context_length": 200000,
        "supported_parameters": ["temperature", "max_tokens"]
      }
      """.data(using: .utf8)!
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let entry = try decoder.decode(OpenRouterModelEntry.self, from: payload)
    #expect(entry.id == "anthropic/claude-3.7-sonnet")
    #expect(entry.contextLength == 200000)
    #expect(entry.supportedParameters == ["temperature", "max_tokens"])
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

  @Test("AcpPermissionBatch decoder rejects non-acp managed_agent_family values")
  func acpPermissionBatchRejectsOpenRouterFamily() throws {
    let payload = """
      {
        "batch_id": "batch-or-1",
        "managed_agent_id": "openrouter-1",
        "managed_agent_family": "open_router",
        "session_id": "11111111-1111-4111-8111-111111111111",
        "requests": [],
        "created_at": "2026-05-20T00:00:00Z",
        "expires_at": "2026-05-20T00:05:00Z"
      }
      """.data(using: .utf8)!
    let decoder = JSONDecoder()
    #expect(throws: DecodingError.self) {
      _ = try decoder.decode(AcpPermissionBatch.self, from: payload)
    }
  }
}
