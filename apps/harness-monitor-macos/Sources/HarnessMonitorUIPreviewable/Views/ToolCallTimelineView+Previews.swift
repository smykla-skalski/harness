import HarnessMonitorKit
import SwiftUI

#Preview("Tool Call Timeline") {
  ToolCallTimelineView(
    entries: toolCallTimelinePreviewEntries,
    liveAnnouncementRowIDs: [toolCallTimelinePreviewRowID],
    overflowNotice: .init(
      sessionID: "session-preview",
      rawUpdateCount: 32,
      displayedEventCount: 6,
      recordedAt: "2026-05-01T12:00:03Z"
    )
  )
  .padding(16)
  .frame(width: 780)
}

private let toolCallTimelinePreviewRowID = "session-preview::acp-preview::call-1"

private let toolCallTimelinePreviewEntries: [TimelineEntry] = [
  TimelineEntry(
    entryId: "preview-call-1-result",
    recordedAt: "2026-05-01T12:00:03Z",
    kind: "tool_result",
    sessionId: "session-preview",
    agentId: "acp-preview",
    taskId: nil,
    summary: "Copilot completed Write",
    payload: .object([
      "runtime": .string("acp"),
      "event": .object([
        "type": .string("tool_result"),
        "tool_name": .string("Write"),
        "invocation_id": .string("call-1"),
        "is_error": .bool(false),
      ]),
      "tool_call_timeline": .object([
        "tool_call_id": .string("call-1"),
        "tool_name": .string("Write"),
        "status": .string("completed"),
        "acp_agent_id": .string("acp-preview"),
        "agent_id": .string("copilot"),
        "agent_display_name": .string("Copilot"),
        "capability_tags": .array([.string("filesystem"), .string("workspace")]),
        "sequence": .number(2),
        "stop_reason": .string("end_turn"),
      ]),
    ])
  ),
  TimelineEntry(
    entryId: "preview-call-1-start",
    recordedAt: "2026-05-01T12:00:01Z",
    kind: "tool_invocation",
    sessionId: "session-preview",
    agentId: "acp-preview",
    taskId: nil,
    summary: "Copilot invoked Write",
    payload: .object([
      "runtime": .string("acp"),
      "event": .object([
        "type": .string("tool_invocation"),
        "tool_name": .string("Write"),
        "invocation_id": .string("call-1"),
      ]),
      "tool_call_timeline": .object([
        "tool_call_id": .string("call-1"),
        "tool_name": .string("Write"),
        "status": .string("started"),
        "acp_agent_id": .string("acp-preview"),
        "agent_id": .string("copilot"),
        "agent_display_name": .string("Copilot"),
        "capability_tags": .array([.string("filesystem"), .string("workspace")]),
        "sequence": .number(1),
      ]),
    ])
  ),
  TimelineEntry(
    entryId: "preview-call-2-failed",
    recordedAt: "2026-05-01T11:59:58Z",
    kind: "tool_result_error",
    sessionId: "session-preview",
    agentId: "acp-preview",
    taskId: nil,
    summary: "Copilot failed Bash",
    payload: .object([
      "runtime": .string("acp"),
      "event": .object([
        "type": .string("tool_result"),
        "tool_name": .string("Bash"),
        "invocation_id": .string("call-2"),
        "is_error": .bool(true),
      ]),
      "tool_call_timeline": .object([
        "tool_call_id": .string("call-2"),
        "tool_name": .string("Bash"),
        "status": .string("failed"),
        "acp_agent_id": .string("acp-preview"),
        "agent_id": .string("copilot"),
        "agent_display_name": .string("Copilot"),
        "capability_tags": .array([.string("shell")]),
        "sequence": .number(3),
        "stop_reason": .string("error"),
      ]),
    ])
  ),
]
