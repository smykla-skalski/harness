import Foundation

private struct RichSessionTimelineDecisionSpec {
  let id: String
  let severity: DecisionSeverity
  let ruleID: String
  let agentID: String
  let taskID: String
  let summary: String
  let createdAt: Date
  let actionsJSON: String
}

private struct RichSessionTimelineEntrySpec {
  let id: String
  let recordedAt: String
  let kind: String
  let agentID: String
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
}
