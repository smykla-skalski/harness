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

  private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    return encoder
  }()

  private let signalPayloadDefaultsFixture = """
    {
      "session": {
        "project_id": "project-b72ed763e074d381",
        "project_name": "harness",
        "project_dir": "/tmp/project",
        "context_root": "/tmp/project/context",
        "checkout_id": "project-b72ed763e074d381",
        "checkout_root": "/tmp/project",
        "is_worktree": false,
        "worktree_name": null,
        "session_id": "sess-signal",
        "context": "Signal decode proof",
        "status": "active",
        "created_at": "2026-04-03T17:23:26Z",
        "updated_at": "2026-04-03T17:23:32Z",
        "last_activity_at": "2026-04-03T17:23:32Z",
        "leader_id": "claude-leader",
        "observe_id": null,
        "pending_leader_transfer": null,
        "metrics": {
          "agent_count": 2,
          "active_agent_count": 2,
          "open_task_count": 0,
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
          "joined_at": "2026-04-03T17:23:26Z",
          "updated_at": "2026-04-03T17:23:26Z",
          "status": "active",
          "last_activity_at": "2026-04-03T17:23:26Z",
          "runtime_capabilities": {
            "runtime": "claude",
            "supports_native_transcript": true,
            "supports_signal_delivery": true,
            "supports_context_injection": true,
            "typical_signal_latency_seconds": 5,
            "hook_points": []
          }
        }
      ],
      "tasks": [],
      "signals": [
        {
          "runtime": "codex",
          "agent_id": "codex-worker",
          "session_id": "sess-signal",
          "status": "acknowledged",
          "signal": {
            "signal_id": "sig-1",
            "version": 1,
            "created_at": "2026-04-03T17:24:00Z",
            "expires_at": "2026-04-03T17:39:00Z",
            "source_agent": "claude-leader",
            "command": "inject_context",
            "priority": "normal",
            "payload": {
              "message": "live payload without extra optional fields"
            },
            "delivery": {
              "max_retries": 3,
              "retry_count": 0,
              "idempotency_key": "sess-signal:codex-worker:inject_context"
            }
          },
          "acknowledgment": {
            "signal_id": "sig-1",
            "acknowledged_at": "2026-04-03T17:24:05Z",
            "result": "accepted",
            "agent": "worker-session",
            "session_id": "sess-signal"
          }
        }
      ],
      "observer": null,
      "agent_activity": []
    }
    """

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

  @Test("Work item decoding accepts queued daemon fields")
  func workItemDecodingAcceptsQueuedDaemonFields() throws {
    let json = """
      {
        "task_id": "task-queued",
        "title": "Queued task",
        "severity": "medium",
        "status": "open",
        "assigned_to": "worker-codex",
        "queue_policy": "reassign_when_free",
        "queued_at": "2026-04-10T08:00:00Z",
        "created_at": "2026-04-10T07:58:00Z",
        "updated_at": "2026-04-10T08:00:00Z"
      }
      """

    let item = try decoder.decode(WorkItem.self, from: Data(json.utf8))

    #expect(item.assignedTo == "worker-codex")
    #expect(item.queuePolicy == .reassignWhenFree)
    #expect(item.queuedAt == "2026-04-10T08:00:00Z")
    #expect(item.isQueuedForWorker)
    #expect(item.isReassignableQueuedTask)
    #expect(item.assignmentSummary == "Queued for worker-codex")
  }

  @Test("Work item decoding exposes pending delivery assignment copy")
  func workItemDecodingExposesPendingDeliveryCopy() throws {
    let json = """
      {
        "task_id": "task-delivery",
        "title": "Deliver task start signal",
        "severity": "medium",
        "status": "open",
        "assigned_to": "worker-codex",
        "created_at": "2026-04-10T07:58:00Z",
        "updated_at": "2026-04-10T08:00:00Z"
      }
      """

    let item = try decoder.decode(WorkItem.self, from: Data(json.utf8))

    #expect(item.isPendingDelivery)
    #expect(!item.isQueuedForWorker)
    #expect(item.assignmentSummary == "Pending delivery to worker-codex")
  }

  @Test("Session signal status decodes legacy acknowledged and encodes delivered")
  func sessionSignalStatusPreservesLegacyDecodeAndNewEncode() throws {
    let decoded = try decoder.decode(
      SessionSignalStatus.self,
      from: Data(#""acknowledged""#.utf8)
    )
    #expect(decoded == .delivered)

    let encoded = try encoder.encode(SessionSignalStatus.delivered)
    let encodedValue = try #require(String(data: encoded, encoding: .utf8))
    #expect(encodedValue == #""delivered""#)
  }

  @Test("Task drop request encodes daemon wire values")
  func taskDropRequestEncodesDaemonWireValues() throws {
    let request = TaskDropRequest(
      actor: "leader-claude",
      target: .agent(agentId: "worker-codex"),
      queuePolicy: .reassignWhenFree
    )

    let data = try encoder.encode(request)
    let object = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let target = try #require(object["target"] as? [String: Any])

    #expect(object["actor"] as? String == "leader-claude")
    #expect(object["queue_policy"] as? String == "reassign_when_free")
    #expect(target["target_type"] as? String == "agent")
    #expect(target["agent_id"] as? String == "worker-codex")
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

  @Test("Session detail decoding defaults omitted signal payload fields")
  func sessionDetailDecodingDefaultsOmittedSignalPayloadFields() throws {
    let detail = try decoder.decode(
      SessionDetail.self,
      from: Data(signalPayloadDefaultsFixture.utf8)
    )

    #expect(detail.signals.count == 1)
    #expect(
      detail.signals[0].signal.payload.message == "live payload without extra optional fields")
    #expect(detail.signals[0].signal.payload.actionHint == nil)
    #expect(detail.signals[0].signal.payload.relatedFiles.isEmpty)
    #expect(detail.signals[0].signal.payload.metadata == .object([:]))
  }

  @Test("SessionStatus accepts leaderless degraded daemon wire value")
  func sessionStatusAcceptsLeaderlessDegradedWireValue() {
    #expect(SessionStatus(rawValue: "leaderless_degraded") != nil)
  }

  @Test("Session summary decoding accepts leaderless degraded daemon payloads")
  func sessionSummaryDecodingAcceptsLeaderlessDegradedPayloads() throws {
    let json = """
      {
        "project_id": "project-890e1bdc449e2a7b",
        "project_name": "kuma",
        "project_dir": "/tmp/project",
        "context_root": "/tmp/project/context",
        "checkout_id": "project-9fe5ce4237976a0a",
        "checkout_root": "/tmp/project/.claude/worktrees/fix-motb-dangling-accesslog",
        "is_worktree": true,
        "worktree_name": "fix-motb-dangling-accesslog",
        "session_id": "sess-20260402100345527324000",
        "title": "Create a test suite",
        "context": "Create a test suite",
        "status": "leaderless_degraded",
        "created_at": "2026-04-02T10:03:45Z",
        "updated_at": "2026-04-17T08:14:49Z",
        "last_activity_at": "2026-04-17T08:14:49Z",
        "leader_id": null,
        "observe_id": "observe-sess-20260402100345527324000",
        "pending_leader_transfer": null,
        "metrics": {
          "agent_count": 0,
          "active_agent_count": 0,
          "open_task_count": 1,
          "in_progress_task_count": 0,
          "blocked_task_count": 0,
          "completed_task_count": 0
        }
      }
      """

    let summary = try decoder.decode(SessionSummary.self, from: Data(json.utf8))

    #expect(summary.status.rawValue == "leaderless_degraded")
    #expect(summary.leaderId == nil)
  }
}
