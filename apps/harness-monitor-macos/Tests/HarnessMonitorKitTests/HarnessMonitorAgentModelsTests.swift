import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Harness Monitor agent models v10")
struct HarnessMonitorAgentModelsTests {
  let decoder = JSONDecoder()
  let encoder = JSONEncoder()

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
          "managed_agent_id": "acp-1",
          "managed_agent_family": "acp",
          "session_id": "session-1",
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
              "managed_agent_id": "acp-1",
              "managed_agent_family": "acp",
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
        "managed_agent_id": "acp-runtime-1",
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
    #expect(json["managed_agent_id"] as? String == "acp-runtime-1")
    #expect(json["managed_agent_family"] as? String == "acp")
    #expect(json["agent_id"] == nil)
    #expect(json["agent_session_id"] == nil)
    #expect(json["managed_agent"] == nil)
  }

  @Test("AgentRegistration rejects partial managed-agent identity")
  func agentRegistrationRejectsPartialManagedAgentIdentity() {
    let data = Data(
      #"""
      {
        "session_agent_id": "copilot-worker",
        "name": "GitHub Copilot",
        "runtime": "copilot",
        "role": "worker",
        "capabilities": [],
        "joined_at": "2026-05-01T17:00:00Z",
        "updated_at": "2026-05-01T17:00:01Z",
        "status": "active",
        "managed_agent_id": "acp-runtime-1",
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

    #expect(throws: DecodingError.self) {
      _ = try decoder.decode(AgentRegistration.self, from: data)
    }
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

  func encodedJSONObject<T: Encodable>(_ value: T) throws -> [String: Any] {
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

}
