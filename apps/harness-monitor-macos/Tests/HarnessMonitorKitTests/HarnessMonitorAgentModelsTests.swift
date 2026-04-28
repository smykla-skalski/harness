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
          "session_id": "session-1",
          "agent_id": "copilot",
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
    #expect(snapshot.acp?.status == .disconnected)
    #expect(snapshot.acp?.disconnectReason?.kind == "process_exited")
    #expect(snapshot.acp?.isRestartable == true)
    #expect(snapshot.acp?.stderrTail == "boom")
  }

  @Test("AgentStatus encodes idle snake case")
  func agentStatusEncodesIdle() throws {
    let data = try encoder.encode(AgentStatus.awaitingReview)
    let string = String(bytes: data, encoding: .utf8)
    #expect(string == "\"awaiting_review\"")
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
}
