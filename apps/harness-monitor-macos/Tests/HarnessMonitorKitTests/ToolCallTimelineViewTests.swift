import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Tool call timeline view")
struct ToolCallTimelineViewTests {
  @Test("Canonical timeline rows fold invocation and result by invocation id")
  @MainActor
  func canonicalRowsFoldInvocationAndResultByInvocationID() throws {
    let entries = [
      TimelineEntry(
        entryId: "acp-acp-1-tool_result-2",
        recordedAt: "2026-04-28T00:00:05Z",
        kind: "tool_result",
        sessionId: "session-1",
        agentId: "acp-1",
        taskId: nil,
        summary: "copilot received a result from Write",
        payload: .object([
          "runtime": .string("acp"),
          "event": .object([
            "type": .string("tool_result"),
            "tool_name": .string("Write"),
            "invocation_id": .string("call-1"),
            "is_error": .bool(false),
          ]),
        ])
      ),
      TimelineEntry(
        entryId: "acp-acp-1-tool_invocation-1",
        recordedAt: "2026-04-28T00:00:00Z",
        kind: "tool_invocation",
        sessionId: "session-1",
        agentId: "acp-1",
        taskId: nil,
        summary: "copilot invoked Write",
        payload: .object([
          "runtime": .string("acp"),
          "event": .object([
            "type": .string("tool_invocation"),
            "tool_name": .string("Write"),
            "invocation_id": .string("call-1"),
          ]),
        ])
      ),
    ]

    let row = try #require(ToolCallTimelineView.materialiseRows(from: entries).first)

    #expect(row.id == "call-1")
    #expect(row.title == "Write")
    #expect(row.status == .completed)
    #expect(row.detail == "copilot received a result from Write")
  }

  @Test("Legacy conversation payload still materialises")
  @MainActor
  func legacyConversationPayloadStillMaterialises() throws {
    let entry = TimelineEntry(
      entryId: "legacy-event-1",
      recordedAt: "2026-04-28T00:00:00Z",
      kind: "conversation_event",
      sessionId: "session-1",
      agentId: "agent-1",
      taskId: nil,
      summary: "agent invoked Bash",
      payload: .object([
        "kind": .object([
          "type": .string("tool_invocation"),
          "tool_name": .string("Bash"),
        ])
      ])
    )

    let row = try #require(ToolCallTimelineView.materialiseRows(from: [entry]).first)

    #expect(row.id == "legacy-event-1")
    #expect(row.title == "Bash")
    #expect(row.status == .started)
  }
}
