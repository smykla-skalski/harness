import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Harness Monitor session models")
struct HarnessMonitorSessionModelsTests {
  private let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }()

  @Test("Work item decoding defaults omitted daemon fields")
  func workItemDecodingDefaultsOmittedDaemonFields() throws {
    let json = """
      {
        "task_id": "task-1",
        "title": "Create test suite",
        "severity": "high",
        "status": "open",
        "created_at": "2026-04-02T11:42:11Z",
        "updated_at": "2026-04-02T11:42:11Z"
      }
      """

    let item = try decoder.decode(WorkItem.self, from: Data(json.utf8))

    #expect(item.taskId == "task-1")
    #expect(item.notes.isEmpty)
    #expect(item.source == .manual)
    #expect(item.assignedTo == nil)
    #expect(item.createdBy == nil)
    #expect(item.checkpointSummary == nil)
  }

  @Test("Session detail decoding accepts daemon task payloads with omitted defaults")
  func sessionDetailDecodingAcceptsDaemonTaskPayloadsWithOmittedDefaults() throws {
    let json = """
      {
        "session": {
          "project_id": "project-9fe5ce4237976a0a",
          "project_name": "project-9fe5ce4237976a0a",
          "project_dir": null,
          "context_root": "/tmp/project",
          "session_id": "sess-20260402100345527324000",
          "context": "Create a test suite",
          "status": "active",
          "created_at": "2026-04-02T10:03:45Z",
          "updated_at": "2026-04-02T11:42:11Z",
          "last_activity_at": "2026-04-02T11:42:11Z",
          "leader_id": "claude-leader",
          "observe_id": "observe-sess-20260402100345527324000",
          "pending_leader_transfer": null,
          "metrics": {
            "agent_count": 2,
            "active_agent_count": 2,
            "open_task_count": 1,
            "in_progress_task_count": 0,
            "blocked_task_count": 0,
            "completed_task_count": 0
          }
        },
        "agents": [
          {
            "agent_id": "claude-leader",
            "name": "claude leader",
            "runtime": "claude",
            "role": "leader",
            "capabilities": [],
            "joined_at": "2026-04-02T10:03:45Z",
            "updated_at": "2026-04-02T11:42:11Z",
            "status": "active",
            "last_activity_at": "2026-04-02T11:42:11Z",
            "runtime_capabilities": {
              "runtime": "claude",
              "supports_native_transcript": true,
              "supports_signal_delivery": true,
              "supports_context_injection": true,
              "typical_signal_latency_seconds": 5,
              "hook_points": [
                {
                  "name": "PreToolUse",
                  "typical_latency_seconds": 5,
                  "supports_context_injection": true
                }
              ]
            }
          }
        ],
        "tasks": [
          {
            "task_id": "task-1",
            "title": "Create test suite",
            "context": "Verify the dangling backendRef fix",
            "severity": "high",
            "status": "open",
            "created_at": "2026-04-02T11:42:11Z",
            "updated_at": "2026-04-02T11:42:11Z",
            "created_by": "claude-leader",
            "source": "manual"
          }
        ],
        "signals": [],
        "observer": null,
        "agent_activity": []
      }
      """

    let detail = try decoder.decode(SessionDetail.self, from: Data(json.utf8))

    #expect(detail.session.sessionId == "sess-20260402100345527324000")
    #expect(detail.tasks.count == 1)
    #expect(detail.tasks[0].notes.isEmpty)
    #expect(detail.tasks[0].source == .manual)
    #expect(detail.agents[0].agentSessionId == nil)
  }
}
