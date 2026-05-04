import Foundation

private struct RichSessionTimelineDecisionSpec {
  let id: String
  let severity: DecisionSeverity
  let ruleID: String
  let agentID: String
  let taskID: String?
  let summary: String
  let createdAt: Date
  let actionsJSON: String
}

private struct RichSessionTimelineEntrySpec {
  let id: String
  let recordedAt: String
  let kind: String
  let agentID: String?
  let taskID: String?
  let summary: String
  let payload: JSONValue
}

extension PreviewFixtures {
  public static var richSessionTimeline: [TimelineEntry] {
    [
      sessionTimelineEntry(
        .init(
          id: "preview-approval-linked",
          recordedAt: "2026-03-28T14:24:15Z",
          kind: "approval_required",
          agentID: "worker-codex",
          taskID: "task-ui",
          summary: "Worker requested approval for the focused preview render.",
          payload: .object(["decisionID": .string("decision-preview-approval")])
        )),
      sessionTimelineEntry(
        .init(
          id: "preview-tool-failed",
          recordedAt: "2026-03-28T14:23:45Z",
          kind: "tool_failed",
          agentID: "worker-codex",
          taskID: "task-ui",
          summary: "preview:render failed once while the host was still reconnecting.",
          payload: .object(["tool": .string("xcode-cli"), "status": .string("failed")])
        )),
      sessionTimelineEntry(
        .init(
          id: "preview-retry-warning",
          recordedAt: "2026-03-28T14:22:50Z",
          kind: "retry_warning",
          agentID: "leader-claude",
          taskID: "task-ui",
          summary: "Leader queued a bounded retry after the first render timeout.",
          payload: .object(["attempt": .number(2)])
        )),
      sessionTimelineEntry(
        .init(
          id: "preview-fast-fling",
          recordedAt: "2026-03-28T14:21:40Z",
          kind: "scroll_checkpoint",
          agentID: "worker-codex",
          taskID: "task-ui",
          summary: "Fast-fling scroll audit reached the older-window prefetch band.",
          payload: .object(["visibleRows": .number(6), "loadedEvents": .number(24)])
        )),
      sessionTimelineEntry(
        .init(
          id: "preview-task-completed",
          recordedAt: "2026-03-28T14:20:10Z",
          kind: "task_completed",
          agentID: "worker-codex",
          taskID: "task-ui",
          summary: "Timeline visibility stats stabilized after variable row heights.",
          payload: .object(["result": .string("success")])
        )),
      sessionTimelineEntry(
        .init(
          id: "preview-signal-sent",
          recordedAt: "2026-03-28T14:18:10Z",
          kind: "signal_sent",
          agentID: "leader-claude",
          taskID: nil,
          summary: "Leader sent validation context to the monitor worker.",
          payload: .object(["command": .string("validate_scroll_window")])
        )),
    ] + Array(pagedTimeline.prefix(12))
  }

  public static var signalSquishTimeline: [TimelineEntry] {
    let liveBorderScenario = [
      RichSessionTimelineEntrySpec(
        id: "preview-live-liveness-disconnected",
        recordedAt: "2026-05-04T13:43:46Z",
        kind: "liveness_synced",
        agentID: nil,
        taskID: nil,
        summary: "Liveness sync: 1 disconnected, 0 idled",
        payload: .object(["status": .string("synced")])
      ),
      RichSessionTimelineEntrySpec(
        id: "preview-live-liveness-idled",
        recordedAt: "2026-05-04T13:30:29Z",
        kind: "liveness_synced",
        agentID: nil,
        taskID: nil,
        summary: "Liveness sync: 0 disconnected, 1 idled",
        payload: .object(["status": .string("synced")])
      ),
      RichSessionTimelineEntrySpec(
        id: "preview-live-liveness-disconnected-and-idled",
        recordedAt: "2026-05-04T13:17:32Z",
        kind: "liveness_synced",
        agentID: nil,
        taskID: nil,
        summary: "Liveness sync: 1 disconnected, 1 idled",
        payload: .object(["status": .string("synced")])
      ),
      RichSessionTimelineEntrySpec(
        id: "preview-live-signal-ack-gemini-expired",
        recordedAt: "2026-05-04T13:17:32Z",
        kind: "signal_acknowledged",
        agentID: "gemini-20260504124513402981000",
        taskID: nil,
        summary:
          "sig-20260504124537520229000 acknowledged by gemini-20260504124513402981000: Expired",
        payload: .object(["result": .string("expired")])
      ),
      RichSessionTimelineEntrySpec(
        id: "preview-live-signal-sent-request-action",
        recordedAt: "2026-05-04T12:45:37Z",
        kind: "signal_sent",
        agentID: "harness-app",
        taskID: nil,
        summary:
          "sig-20260504124537520229000 sent to gemini-20260504124513402981000: request_action",
        payload: .object(["command": .string("request_action")])
      ),
      RichSessionTimelineEntrySpec(
        id: "preview-live-agent-joined-worker",
        recordedAt: "2026-05-04T12:45:13Z",
        kind: "agent_joined",
        agentID: nil,
        taskID: nil,
        summary: "gemini-20260504124513402981000 joined as Worker (gemini)",
        payload: .object(["role": .string("worker")])
      ),
      RichSessionTimelineEntrySpec(
        id: "preview-live-liveness-post-join",
        recordedAt: "2026-05-04T12:45:13Z",
        kind: "liveness_synced",
        agentID: nil,
        taskID: nil,
        summary: "Liveness sync: 0 disconnected, 1 idled",
        payload: .object(["status": .string("synced")])
      ),
    ]

    let historicalTail = [
      RichSessionTimelineEntrySpec(
        id: "preview-liveness-1",
        recordedAt: "2026-05-03T21:28:11Z",
        kind: "liveness_synced",
        agentID: "harness-app",
        taskID: nil,
        summary: "Liveness sync: 1 disconnected, 0 idled",
        payload: .object(["status": .string("synced")])
      ),
      RichSessionTimelineEntrySpec(
        id: "preview-agent-joined",
        recordedAt: "2026-05-03T21:15:12Z",
        kind: "agent_joined",
        agentID: nil,
        taskID: nil,
        summary: "gemini-20260504124323411402000 joined as Leader (gemini)",
        payload: .object(["role": .string("leader")])
      ),
      RichSessionTimelineEntrySpec(
        id: "preview-liveness-2",
        recordedAt: "2026-05-03T21:02:03Z",
        kind: "liveness_synced",
        agentID: "harness-app",
        taskID: nil,
        summary: "Liveness sync: 0 disconnected, 1 idled",
        payload: .object(["status": .string("synced")])
      ),
      RichSessionTimelineEntrySpec(
        id: "preview-liveness-3",
        recordedAt: "2026-05-03T21:02:03Z",
        kind: "liveness_synced",
        agentID: "harness-app",
        taskID: nil,
        summary: "Liveness sync: 0 disconnected, 1 idled",
        payload: .object(["status": .string("synced")])
      ),
      RichSessionTimelineEntrySpec(
        id: "preview-observe-snapshot",
        recordedAt: "2026-05-03T21:03:34Z",
        kind: "observe_snapshot",
        agentID: nil,
        taskID: nil,
        summary: "Observe scan: 0 open, 0 active workers, 0 muted codes",
        payload: .object(["scope": .string("timeline")])
      ),
      RichSessionTimelineEntrySpec(
        id: "preview-signal-ack-copilot-expired",
        recordedAt: "2026-05-03T21:00:24Z",
        kind: "signal_acknowledged",
        agentID: "copilot-20260503203910393668000",
        taskID: nil,
        summary:
          "sig-20260503204520733172000 acknowledged by copilot-20260503203910393668000: Expired",
        payload: .object(["result": .string("expired")])
      ),
      RichSessionTimelineEntrySpec(
        id: "preview-liveness-4",
        recordedAt: "2026-05-03T20:56:36Z",
        kind: "liveness_synced",
        agentID: "harness-app",
        taskID: nil,
        summary: "Liveness sync: 0 disconnected, 1 idled",
        payload: .object(["status": .string("synced")])
      ),
      RichSessionTimelineEntrySpec(
        id: "preview-signal-ack-gemini-expired-1",
        recordedAt: "2026-05-03T20:55:00Z",
        kind: "signal_acknowledged",
        agentID: "gemini-20260503201702585333000",
        taskID: nil,
        summary:
          "sig-20260503203959657678000 acknowledged by gemini-20260503201702585333000: Expired",
        payload: .object(["result": .string("expired")])
      ),
      RichSessionTimelineEntrySpec(
        id: "preview-signal-ack-gemini-expired-2",
        recordedAt: "2026-05-03T20:55:00Z",
        kind: "signal_acknowledged",
        agentID: "gemini-20260503201702585333000",
        taskID: nil,
        summary:
          "sig-20260503203959723499000 acknowledged by gemini-20260503201702585333000: Expired",
        payload: .object(["result": .string("expired")])
      ),
      RichSessionTimelineEntrySpec(
        id: "preview-liveness-5",
        recordedAt: "2026-05-03T20:50:00Z",
        kind: "liveness_synced",
        agentID: "harness-app",
        taskID: nil,
        summary: "Liveness sync: 1 disconnected, 0 idled",
        payload: .object(["status": .string("synced")])
      ),
    ]

    return (liveBorderScenario + historicalTail).map(sessionTimelineEntry)
      + Array(pagedTimeline.prefix(11))
  }

  public static var signalSquishTimelineDecisions: [Decision] {
    [
      sessionTimelineDecision(
        .init(
          id: "idle-session:nod8ccog",
          severity: .warn,
          ruleID: "idle-session",
          agentID: "gemini-20260504124513402981000",
          taskID: nil,
          summary: "Session nod8ccog has had no activity for over 600s.",
          createdAt: previewDate("2026-05-04T13:17:42Z"),
          actionsJSON: idleSessionActionsJSON
        ))
    ]
  }

  public static var richSessionTimelineDecisions: [Decision] {
    [
      sessionTimelineDecision(
        .init(
          id: "decision-preview-approval",
          severity: .needsUser,
          ruleID: "codex.approval",
          agentID: "worker-codex",
          taskID: "task-ui",
          summary: "Approve retrying the preview render after host reconnect.",
          createdAt: Date(timeIntervalSince1970: 1_774_700_655),
          actionsJSON: approvalActionsJSON
        )),
      sessionTimelineDecision(
        .init(
          id: "decision-preview-critical",
          severity: .critical,
          ruleID: "timeline.fast_fling_gap",
          agentID: "worker-codex",
          taskID: "task-ui",
          summary: "Fast fling found a missing loaded-window buffer.",
          createdAt: Date(timeIntervalSince1970: 1_774_700_610),
          actionsJSON: repairActionsJSON
        )),
      sessionTimelineDecision(
        .init(
          id: "decision-preview-warning",
          severity: .warn,
          ruleID: "timeline.preview_richness",
          agentID: "leader-claude",
          taskID: "task-ui",
          summary: "Preview should show warning, success, info, and action states.",
          createdAt: Date(timeIntervalSince1970: 1_774_700_555),
          actionsJSON: previewActionsJSON
        )),
    ]
  }

  public static var richSessionTimelineWindow: TimelineWindowResponse {
    let entries = richSessionTimeline
    return TimelineWindowResponse(
      revision: 7,
      totalCount: 48,
      windowStart: 0,
      windowEnd: entries.count,
      hasOlder: true,
      hasNewer: false,
      oldestCursor: entries.last.map {
        TimelineCursor(recordedAt: $0.recordedAt, entryId: $0.entryId)
      },
      newestCursor: entries.first.map {
        TimelineCursor(recordedAt: $0.recordedAt, entryId: $0.entryId)
      },
      entries: nil,
      unchanged: false
    )
  }

  public static var signalSquishTimelineWindow: TimelineWindowResponse {
    let entries = signalSquishTimeline
    return TimelineWindowResponse(
      revision: 10,
      totalCount: entries.count,
      windowStart: 0,
      windowEnd: entries.count,
      hasOlder: false,
      hasNewer: false,
      oldestCursor: entries.last.map {
        TimelineCursor(recordedAt: $0.recordedAt, entryId: $0.entryId)
      },
      newestCursor: entries.first.map {
        TimelineCursor(recordedAt: $0.recordedAt, entryId: $0.entryId)
      },
      entries: nil,
      unchanged: false
    )
  }

  private static let approvalActionsJSON = #"""
    [
      {
        "id": "approve-retry",
        "title": "Approve Retry",
        "kind": "nudge",
        "payloadJSON": "{}"
      },
      {
        "id": "snooze-15m",
        "title": "Snooze 15m",
        "kind": "snooze",
        "payloadJSON": "{\"duration\":900}"
      },
      {
        "id": "dismiss-approval",
        "title": "Dismiss",
        "kind": "dismiss",
        "payloadJSON": "{}"
      }
    ]
    """#
  private static let repairActionsJSON = #"""
    [
      {
        "id": "assign-repair",
        "title": "Assign Repair",
        "kind": "assignTask",
        "payloadJSON": "{}"
      },
      {
        "id": "defer-repair",
        "title": "Snooze 1h",
        "kind": "snooze",
        "payloadJSON": "{\"duration\":3600}"
      },
      {
        "id": "dismiss-repair",
        "title": "Dismiss",
        "kind": "dismiss",
        "payloadJSON": "{}"
      }
    ]
    """#
  private static let previewActionsJSON = #"""
    [
      {
        "id": "open-preview",
        "title": "Open Preview",
        "kind": "custom",
        "payloadJSON": "{}"
      },
      {
        "id": "dismiss-preview",
        "title": "Dismiss",
        "kind": "dismiss",
        "payloadJSON": "{}"
      }
    ]
    """#
  private static let idleSessionActionsJSON = #"""
    [
      {
        "id": "idle-session.nudge.gemini-20260504124513402981000",
        "title": "Send check-in nudge",
        "kind": "nudge",
        "payloadJSON": "{\"agentID\":\"gemini-20260504124513402981000\",\"input\":\"Quick check-in from Harness Monitor supervisor for idle session nod8ccog.\"}"
      },
      {
        "id": "idle-session.close.nod8ccog",
        "title": "Close session",
        "kind": "custom",
        "payloadJSON": "{\"mode\":\"closeSession\",\"sessionID\":\"nod8ccog\"}"
      },
      {
        "id": "dismiss-idle-session",
        "title": "Dismiss",
        "kind": "dismiss",
        "payloadJSON": "{}"
      }
    ]
    """#
  private static func sessionTimelineDecision(_ spec: RichSessionTimelineDecisionSpec) -> Decision {
    let decision = Decision(
      id: spec.id,
      severity: spec.severity,
      ruleID: spec.ruleID,
      sessionID: Self.summary.sessionId,
      agentID: spec.agentID,
      taskID: spec.taskID,
      summary: spec.summary,
      contextJSON: "{}",
      suggestedActionsJSON: spec.actionsJSON
    )
    decision.createdAt = spec.createdAt
    return decision
  }

  private static func sessionTimelineEntry(_ spec: RichSessionTimelineEntrySpec) -> TimelineEntry {
    TimelineEntry(
      entryId: spec.id,
      recordedAt: spec.recordedAt,
      kind: spec.kind,
      sessionId: Self.summary.sessionId,
      agentId: spec.agentID,
      taskId: spec.taskID,
      summary: spec.summary,
      payload: spec.payload
    )
  }

  private static func previewDate(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    guard let date = formatter.date(from: value) else {
      preconditionFailure("Invalid preview fixture date: \(value)")
    }
    return date
  }
}
