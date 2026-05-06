import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Harness Monitor agent models v10")
struct HarnessMonitorAgentModelsTests {
  private let decoder = JSONDecoder()
  private let encoder = JSONEncoder()

  init() {
    decoder.keyDecodingStrategy = .convertFromSnakeCase
  }

  @Test("AgentStatus decodes awaiting_review snake case")
  func agentStatusDecodesAwaitingReview() throws {
    let data = Data("\"awaiting_review\"".utf8)
    let status = try decoder.decode(AgentStatus.self, from: data)
    #expect(status == .awaitingReview)
  }

  @Test("AgentStatus decodes idle")
  func agentStatusDecodesIdle() throws {
    let data = Data("\"idle\"".utf8)
    let status = try decoder.decode(AgentStatus.self, from: data)
    #expect(status == .idle)
  }

  @Test("AgentStatus decodes disconnected object")
  func agentStatusDecodesDisconnectedObject() throws {
    let data = Data(#"{"state":"disconnected","reason":{"kind":"daemon_shutdown"}}"#.utf8)
    let status = try decoder.decode(AgentStatus.self, from: data)
    #expect(status == .disconnected)
  }

  @Test("ManagedAgentSnapshot decodes ACP snapshot")
  func managedAgentSnapshotDecodesAcp() throws {
    let data = Data(
      #"""
      {
        "kind": "acp",
        "snapshot": {
          "acp_id": "acp-1",
          "managed_agent_id": "acp-1",
          "session_id": "session-1",
          "agent_id": "copilot",
          "session_agent_id": "copilot",
          "display_name": "Copilot",
          "status": {
            "state": "disconnected",
            "reason": { "kind": "process_exited", "code": 1 },
            "stderr_tail": "boom"
          },
          "pid": 42,
          "pgid": 42,
          "project_dir": "/tmp/project",
          "pending_permissions": 1,
          "permission_queue_depth": 1,
          "pending_permission_batches": [
            {
              "batch_id": "batch-1",
              "acp_id": "acp-1",
              "managed_agent_id": "acp-1",
              "session_id": "session-1",
              "created_at": "2026-04-28T00:00:00Z",
              "requests": [
                {
                  "request_id": "request-1",
                  "session_id": "session-1",
                  "tool_call": { "name": "write_file" },
                  "options": []
                }
              ]
            }
          ],
          "terminal_count": 0,
          "created_at": "2026-04-28T00:00:00Z",
          "updated_at": "2026-04-28T00:00:01Z"
        }
      }
      """#.utf8
    )
    let snapshot = try decoder.decode(ManagedAgentSnapshot.self, from: data)
    #expect(snapshot.agentId == "acp-1")
    #expect(snapshot.managedAgentID == "acp-1")
    #expect(snapshot.sessionAgentID == "copilot")
    #expect(snapshot.family == .acp)
    #expect(snapshot.acp?.status == .disconnected)
    #expect(snapshot.acp?.disconnectReason?.kind == "process_exited")
    #expect(snapshot.acp?.isRestartable == true)
    #expect(snapshot.acp?.stderrTail == "boom")
  }

  @Test("AgentRegistration decodes tagged ACP runtime shape")
  func agentRegistrationDecodesTaggedAcpRuntime() throws {
    let data = Data(
      #"""
      {
        "session_agent_id": "copilot-worker",
        "name": "GitHub Copilot",
        "runtime": {
          "kind": "acp",
          "id": "copilot"
        },
        "role": "worker",
        "capabilities": [],
        "joined_at": "2026-05-01T17:00:00Z",
        "updated_at": "2026-05-01T17:00:01Z",
        "status": "active",
        "runtime_session_id": "acp-session-1",
        "managed_agent": {
          "kind": "acp",
          "id": "acp-runtime-1"
        },
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

    let registration = try decoder.decode(AgentRegistration.self, from: data)

    #expect(registration.agentId == "copilot-worker")
    #expect(registration.sessionAgentID == "copilot-worker")
    #expect(registration.runtime == "copilot")
    #expect(registration.agentSessionId == "acp-session-1")
    #expect(registration.runtimeSessionID == "acp-session-1")
    #expect(registration.managedAgent?.kind == .acp)
    #expect(registration.managedAgentID == "acp-runtime-1")
    #expect(registration.status == .active)
  }

  @Test("AgentRegistration encodes canonical identity fields only")
  func agentRegistrationEncodesCanonicalIdentityFieldsOnly() throws {
    let registration = AgentRegistration(
      agentId: "copilot-worker",
      name: "GitHub Copilot",
      runtime: "copilot",
      role: .worker,
      capabilities: [],
      joinedAt: "2026-05-01T17:00:00Z",
      updatedAt: "2026-05-01T17:00:01Z",
      status: .active,
      agentSessionId: "acp-session-1",
      managedAgent: ManagedAgentRef(kind: .acp, id: "acp-runtime-1"),
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

    let json = try encodedJSONObject(registration)

    #expect(json["session_agent_id"] as? String == "copilot-worker")
    #expect(json["runtime_session_id"] as? String == "acp-session-1")
    #expect(json["agent_id"] == nil)
    #expect(json["agent_session_id"] == nil)
  }

  @Test("Transport-closed disconnect is restartable")
  func transportClosedDisconnectIsRestartable() {
    let reason = AgentDisconnectReason(kind: "transport_closed", code: nil, signal: nil)
    #expect(reason.isRestartable == true)
  }

  @Test("ACP permission decision wire format matches daemon")
  func acpPermissionDecisionWireFormat() throws {
    let approveAll = try encodedJSONObject(AcpPermissionDecision.approveAll)
    #expect(approveAll["decision"] as? String == "approve_all")
    #expect(approveAll["request_ids"] == nil)

    let approveSome = try encodedJSONObject(AcpPermissionDecision.approveSome(["request-2"]))
    #expect(approveSome["decision"] as? String == "approve_some")
    #expect(approveSome["request_ids"] as? [String] == ["request-2"])

    let denyAll = try encodedJSONObject(AcpPermissionDecision.denyAll)
    #expect(denyAll["decision"] as? String == "deny_all")
  }

  @Test("AgentStatus encodes idle snake case")
  func agentStatusEncodesIdle() throws {
    let data = try encoder.encode(AgentStatus.awaitingReview)
    let string = String(bytes: data, encoding: .utf8)
    #expect(string == "\"awaiting_review\"")
  }

  private func encodedJSONObject<T: Encodable>(_ value: T) throws -> [String: Any] {
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let data = try encoder.encode(value)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @Test("AgentStatus sort priority reorders awaiting review")
  func agentStatusSortPriorityReorder() {
    #expect(AgentStatus.active.sortPriority == 0)
    #expect(AgentStatus.awaitingReview.sortPriority == 1)
    #expect(AgentStatus.idle.sortPriority == 2)
    #expect(AgentStatus.disconnected.sortPriority == 3)
    #expect(AgentStatus.removed.sortPriority == 4)
  }

  @Test("AgentStatus decodes legacy camelCase awaitingReview")
  func agentStatusLegacyCamelCaseFallback() throws {
    let data = Data("\"awaitingReview\"".utf8)
    let status = try decoder.decode(AgentStatus.self, from: data)
    #expect(status == .awaitingReview)
  }

  @Test("AgentRegistration.isAutoSpawned true when capability present")
  func agentRegistrationIsAutoSpawnedFromCapabilities() {
    let capabilities = RuntimeCapabilities(
      runtime: "claude",
      supportsNativeTranscript: true,
      supportsSignalDelivery: true,
      supportsContextInjection: true,
      typicalSignalLatencySeconds: 1,
      hookPoints: []
    )
    let auto = AgentRegistration(
      agentId: "rev-1",
      name: "Reviewer",
      runtime: "claude",
      role: .reviewer,
      capabilities: [AgentRegistration.autoSpawnedCapability],
      joinedAt: "2026-04-24T00:00:00Z",
      updatedAt: "2026-04-24T00:00:00Z",
      status: .active,
      agentSessionId: nil,
      lastActivityAt: nil,
      currentTaskId: nil,
      runtimeCapabilities: capabilities,
      persona: nil
    )
    let manual = AgentRegistration(
      agentId: "rev-2",
      name: "Reviewer",
      runtime: "claude",
      role: .reviewer,
      capabilities: ["general"],
      joinedAt: "2026-04-24T00:00:00Z",
      updatedAt: "2026-04-24T00:00:00Z",
      status: .active,
      agentSessionId: nil,
      lastActivityAt: nil,
      currentTaskId: nil,
      runtimeCapabilities: capabilities,
      persona: nil
    )
    #expect(auto.isAutoSpawned)
    #expect(!manual.isAutoSpawned)
  }

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

    #expect(String(decoding: try encoder.encode(managedAgentID), as: UTF8.self) == "\"managed-1\"")
    #expect(try decoder.decode(ManagedAgentID.self, from: Data("\"managed-1\"".utf8)) == managedAgentID)
    #expect(String(decoding: try encoder.encode(sessionID), as: UTF8.self) == "\"session-1\"")
    #expect(String(decoding: try encoder.encode(batchID), as: UTF8.self) == "\"batch-1\"")
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
    let runtimeState = try #require(AcpAgentRuntimeState(snapshot: acp, inspect: nil, inspectSampledAt: nil))

    #expect(registration.sessionAgentIdentity == SessionAgentID(rawValue: "worker-typed"))
    #expect(registration.runtimeSessionIdentity == Optional(RuntimeSessionID(rawValue: "runtime-session-typed")))
    #expect(registration.managedAgentIdentity == Optional(ManagedAgentID(rawValue: "acp-typed")))
    #expect(terminal.sessionIdentity == sessionID)
    #expect(terminal.managedAgentIdentity == ManagedAgentID(rawValue: "tui-typed"))
    #expect(terminal.sessionAgentIdentity == SessionAgentID(rawValue: "agent-tui-typed"))
    #expect(codex.sessionIdentity == sessionID)
    #expect(codex.managedAgentIdentity == ManagedAgentID(rawValue: "codex-typed"))
    #expect(codex.sessionAgentIdentity == nil)
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
    #expect(ManagedAgentSnapshot.acp(acp).sessionAgentIdentity == Optional(acp.sessionAgentIdentity))
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
