import Foundation
import Testing

@testable import HarnessMonitorKit

extension HarnessMonitorAgentModelsTests {
  @Test("AgentPendingUserPrompt decodes canonical ask-user questions")
  func agentPendingUserPromptDecodesCanonicalQuestions() throws {
    let data = Data(
      """
      {
        "tool_name": "AskUserQuestion",
        "waiting_since": "2026-04-28T08:00:01Z",
        "questions": [{
          "question": "Approve the file write?",
          "header": "Approval",
          "options": [
            { "label": "Allow", "description": "Proceed with the write" },
            { "label": "Deny", "description": "Stop before writing" }
          ],
          "multi_select": false
        }]
      }
      """.utf8
    )

    let prompt = try decoder.decode(AgentPendingUserPrompt.self, from: data)

    #expect(prompt.toolName == "AskUserQuestion")
    #expect(prompt.waitingSince == "2026-04-28T08:00:01Z")
    #expect(prompt.primaryQuestion?.header == "Approval")
    #expect(prompt.primaryQuestion?.options.map(\.label) == ["Allow", "Deny"])
  }

  @Test("ACP snapshot id uses the stable agent identifier")
  func acpSnapshotIDUsesAgentIdentifier() {
    let snapshot = AcpAgentSnapshot(
      acpId: "acp-runtime-2",
      sessionId: "session-1",
      agentId: "worker-codex",
      displayName: "Worker",
      status: .active,
      pid: 42,
      pgid: 42,
      projectDir: "/tmp/project",
      pendingPermissions: 0,
      permissionQueueDepth: 0,
      pendingPermissionBatches: [],
      terminalCount: 0,
      createdAt: "2026-05-01T00:00:00Z",
      updatedAt: "2026-05-01T00:00:00Z"
    )

    #expect(snapshot.id == "worker-codex")
    #expect(snapshot.managedAgentID == "acp-runtime-2")
    #expect(snapshot.sessionAgentID == "worker-codex")
  }

  @Test("Identity wrappers encode as single JSON strings")
  func identityWrappersEncodeAsSingleJSONStrings() throws {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    let managedAgentID = ManagedAgentID(rawValue: "managed-1")
    let sessionID = HarnessSessionID(rawValue: "session-1")
    let batchID = AcpPermissionBatchID(rawValue: "batch-1")

    let managedAgentString = try #require(
      String(bytes: encoder.encode(managedAgentID), encoding: .utf8))
    let sessionString = try #require(String(bytes: encoder.encode(sessionID), encoding: .utf8))
    let batchString = try #require(String(bytes: encoder.encode(batchID), encoding: .utf8))

    #expect(managedAgentString == "\"managed-1\"")
    #expect(
      try decoder.decode(ManagedAgentID.self, from: Data("\"managed-1\"".utf8)) == managedAgentID)
    #expect(sessionString == "\"session-1\"")
    #expect(batchString == "\"batch-1\"")
  }

  @Test("Core managed-agent models expose typed identity wrappers")
  func coreManagedAgentModelsExposeTypedIdentityWrappers() throws {
    let client = RecordingHarnessClient()
    let sessionID = HarnessSessionID(rawValue: "session-typed")
    let approval = client.codexApprovalFixture(approvalID: "approval-typed")
    let terminal = client.agentTuiFixture(tuiID: "tui-typed", sessionID: sessionID.rawValue)
    let codex = client.codexRunFixture(
      runID: "codex-typed",
      sessionID: sessionID.rawValue,
      pendingApprovals: [approval]
    )
    let permissionItem = AcpPermissionItem(
      requestId: "request-typed",
      sessionId: sessionID.rawValue,
      toolCall: .object(["name": .string("write_file")]),
      options: []
    )
    let permissionBatch = AcpPermissionBatch(
      batchId: "batch-typed",
      acpId: "acp-typed",
      sessionId: sessionID.rawValue,
      requests: [permissionItem],
      createdAt: "2026-05-01T00:00:00Z"
    )
    let acp = AcpAgentSnapshot(
      acpId: "acp-typed",
      sessionId: sessionID.rawValue,
      agentId: "worker-typed",
      displayName: "Worker",
      status: .active,
      pid: 7,
      pgid: 7,
      projectDir: "/tmp/project",
      pendingPermissions: 1,
      permissionQueueDepth: 1,
      pendingPermissionBatches: [permissionBatch],
      terminalCount: 0,
      createdAt: "2026-05-01T00:00:00Z",
      updatedAt: "2026-05-01T00:00:01Z"
    )
    let registration = AgentRegistration(
      agentId: "worker-typed",
      name: "Worker",
      runtime: "copilot",
      role: .worker,
      capabilities: [],
      joinedAt: "2026-05-01T00:00:00Z",
      updatedAt: "2026-05-01T00:00:01Z",
      status: .active,
      agentSessionId: "runtime-session-typed",
      managedAgent: ManagedAgentRef(kind: .acp, id: acp.managedAgentID),
      lastActivityAt: nil,
      currentTaskId: nil,
      runtimeCapabilities: RuntimeCapabilities(
        runtime: "copilot",
        supportsNativeTranscript: true,
        supportsSignalDelivery: true,
        supportsContextInjection: true,
        typicalSignalLatencySeconds: 5,
        hookPoints: []
      ),
      persona: nil
    )
    let runtimeState = try #require(
      AcpAgentRuntimeState(snapshot: acp, inspect: nil, inspectSampledAt: nil))

    #expect(registration.sessionAgentIdentity == SessionAgentID(rawValue: "worker-typed"))
    #expect(
      registration.runtimeSessionIdentity
        == Optional(RuntimeSessionID(rawValue: "runtime-session-typed")))
    #expect(registration.managedAgentIdentity == Optional(ManagedAgentID(rawValue: "acp-typed")))
    #expect(terminal.sessionIdentity == sessionID)
    #expect(terminal.managedAgentIdentity == ManagedAgentID(rawValue: "tui-typed"))
    #expect(terminal.sessionAgentIdentity == SessionAgentID(rawValue: "agent-tui-typed"))
    #expect(codex.sessionIdentity == sessionID)
    #expect(codex.managedAgentIdentity == ManagedAgentID(rawValue: "codex-typed"))
    #expect(codex.sessionAgentIdentity == Optional(SessionAgentID(rawValue: "codex-worker")))
    #expect(codex.threadIdentity == Optional(CodexThreadID(rawValue: "thread-codex-typed")))
    #expect(approval.approvalIdentity == CodexApprovalID(rawValue: "approval-typed"))
    #expect(approval.requestIdentity == CodexApprovalRequestID(rawValue: "json-rpc-approval-1"))
    #expect(permissionItem.requestIdentity == AcpPermissionRequestID(rawValue: "request-typed"))
    #expect(permissionBatch.batchIdentity == AcpPermissionBatchID(rawValue: "batch-typed"))
    #expect(permissionBatch.managedAgentIdentity == ManagedAgentID(rawValue: "acp-typed"))
    #expect(acp.sessionIdentity == sessionID)
    #expect(acp.managedAgentIdentity == ManagedAgentID(rawValue: "acp-typed"))
    #expect(acp.sessionAgentIdentity == SessionAgentID(rawValue: "worker-typed"))
    #expect(runtimeState.sessionIdentity == sessionID)
    #expect(runtimeState.managedAgentIdentity == ManagedAgentID(rawValue: "acp-typed"))
    #expect(runtimeState.sessionAgentIdentity == SessionAgentID(rawValue: "worker-typed"))
    #expect(ManagedAgentSnapshot.terminal(terminal).sessionIdentity == sessionID)
    #expect(ManagedAgentSnapshot.codex(codex).managedAgentIdentity == codex.managedAgentIdentity)
    #expect(
      ManagedAgentSnapshot.acp(acp).sessionAgentIdentity == Optional(acp.sessionAgentIdentity))
  }

  @Test("Agent registration rejects legacy identity aliases")
  func agentRegistrationRejectsLegacyIdentityAliases() throws {
    let data = Data(
      #"""
      {
        "agent_id": "legacy-agent",
        "name": "Worker",
        "runtime": { "kind": "acp", "id": "copilot" },
        "descriptor_id": "copilot",
        "role": "worker",
        "capabilities": ["acp"],
        "joined_at": "2026-05-01T00:00:00Z",
        "updated_at": "2026-05-01T00:00:01Z",
        "status": "active",
        "agent_session_id": "legacy-runtime",
        "managed_agent_id": "acp-1",
        "managed_agent_family": "acp",
        "runtime_capabilities": {
          "runtime": "copilot",
          "supports_native_transcript": true,
          "supports_signal_delivery": true,
          "supports_context_injection": true,
          "typical_signal_latency_seconds": 5,
          "hook_points": []
        }
      }
      """#.utf8
    )

    do {
      _ = try decoder.decode(AgentRegistration.self, from: data)
      Issue.record("Expected legacy identity aliases to fail decoding")
    } catch {
      #expect(true)
    }
  }
}
