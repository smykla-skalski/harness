import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("Tool call timeline view")
struct ToolCallTimelineViewTests {
  @Test("Canonical timeline rows fold invocation and result by invocation id")
  func canonicalRowsFoldInvocationAndResultByInvocationID() throws {
    let entries = [
      makeCanonicalEntry(
        entryId: "acp-acp-1-tool_result-2",
        recordedAt: "2026-04-28T00:00:05Z",
        kind: "tool_result",
        summary: "copilot received a result from Write",
        event: [
          "type": .string("tool_result"),
          "tool_name": .string("Write"),
          "invocation_id": .string("call-1"),
          "is_error": .bool(false),
        ]
      ),
      makeCanonicalEntry(
        entryId: "acp-acp-1-tool_invocation-1",
        recordedAt: "2026-04-28T00:00:00Z",
        kind: "tool_invocation",
        summary: "copilot invoked Write",
        event: [
          "type": .string("tool_invocation"),
          "tool_name": .string("Write"),
          "invocation_id": .string("call-1"),
        ]
      ),
    ]

    let row = try #require(ToolCallTimelineView.materialiseRows(from: entries).first)

    #expect(row.id == "session-1::acp-1::call-1")
    #expect(row.title == "Write")
    #expect(row.status == .completed)
    #expect(row.detail == "copilot received a result from Write")
  }

  @Test("Legacy conversation payload still materialises")
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
          "invocation_id": .string("call-legacy"),
        ])
      ])
    )

    let row = try #require(ToolCallTimelineView.materialiseRows(from: [entry]).first)

    #expect(row.id == "session-1::agent-1::call-legacy")
    #expect(row.title == "Bash")
    #expect(row.status == .started)
  }

  @Test("Renderer still collapses duplicate tool call ids deterministically")
  func rendererStillCollapsesDuplicateToolCallIDsDeterministically() throws {
    let entries = [
      makeCanonicalEntry(
        entryId: "dup-1",
        recordedAt: "2026-04-28T00:00:00Z",
        kind: "tool_invocation",
        summary: "copilot invoked Bash",
        event: [
          "type": .string("tool_invocation"),
          "tool_name": .string("Bash"),
          "invocation_id": .string("call-dup"),
        ]
      ),
      makeCanonicalEntry(
        entryId: "dup-2",
        recordedAt: "2026-04-28T00:00:02Z",
        kind: "tool_invocation",
        summary: "copilot invoked Bash again",
        event: [
          "type": .string("tool_invocation"),
          "tool_name": .string("Bash"),
          "invocation_id": .string("call-dup"),
        ]
      ),
    ]

    let presentation = ToolCallTimelineView.materialisePresentation(from: entries)
    let row = try #require(presentation.rows.first)

    #expect(presentation.rows.count == 1)
    #expect(row.id == "session-1::acp-1::call-dup")
    #expect(row.detail == "copilot invoked Bash again")
  }

  @Test("Default announcements only fire for terminal states")
  func defaultAnnouncementsOnlyFireForTerminalStates() throws {
    let startedRow = try #require(
      ToolCallTimelineRow(
        entry: makeAnnotatedToolCallEntry(
          entryId: "call-started",
          recordedAt: "2026-04-28T00:00:00Z",
          status: "started",
          stopReason: nil
        )
      )
    )
    let completedRow = try #require(
      ToolCallTimelineRow(
        entry: makeAnnotatedToolCallEntry(
          entryId: "call-completed",
          recordedAt: "2026-04-28T00:00:01Z",
          status: "completed",
          stopReason: "end_turn"
        )
      )
    )
    let failedRow = try #require(
      ToolCallTimelineRow(
        entry: makeAnnotatedToolCallEntry(
          entryId: "call-failed",
          recordedAt: "2026-04-28T00:00:02Z",
          status: "failed",
          stopReason: "error"
        )
      )
    )

    #expect(startedRow.stopReason == nil)
    #expect(completedRow.stopReason == "end_turn")
    #expect(failedRow.stopReason == "error")
    #expect(completedRow.announcementText == "Copilot completed Write. Ended turn.")
    #expect(failedRow.announcementText == "Copilot failed Write. Error.")
    #expect(
      ToolCallTimelineView.shouldAnnounceToolCallStatusChange(
        previousStatus: nil,
        row: startedRow,
        verboseAnnouncements: false
      ) == false
    )
    #expect(
      ToolCallTimelineView.shouldAnnounceToolCallStatusChange(
        previousStatus: .started,
        row: completedRow,
        verboseAnnouncements: false
      )
    )
    #expect(
      ToolCallTimelineView.shouldAnnounceToolCallStatusChange(
        previousStatus: .started,
        row: failedRow,
        verboseAnnouncements: false
      )
    )
  }

  @Test("Announcement helper suppresses backlog hydration and session replacement")
  func announcementHelperSuppressesBacklogHydrationAndSessionReplacement() throws {
    let terminalRow = try #require(
      ToolCallTimelineRow(
        entry: makeAnnotatedToolCallEntry(
          entryId: "call-terminal",
          recordedAt: "2026-04-28T00:00:01Z",
          status: "completed",
          stopReason: "end_turn"
        )
      )
    )

    #expect(
      ToolCallTimelineView.orderedAnnouncementRows(
        previousStates: [:],
        rows: [terminalRow],
        liveAnnouncementRowIDs: [],
        verboseAnnouncements: false
      )
      .isEmpty
    )
    #expect(
      ToolCallTimelineView.orderedAnnouncementRows(
        previousStates: ["other-session-call": .started],
        rows: [terminalRow],
        liveAnnouncementRowIDs: [],
        verboseAnnouncements: false
      )
      .isEmpty
    )
    #expect(
      ToolCallTimelineView.orderedAnnouncementRows(
        previousStates: [:],
        rows: [terminalRow],
        liveAnnouncementRowIDs: [terminalRow.id],
        verboseAnnouncements: false
      )
      .map(\.id) == [terminalRow.id]
    )
  }

  @Test("Announcement helper follows visible timeline order")
  func announcementHelperFollowsVisibleTimelineOrder() throws {
    let newerRow = try #require(
      ToolCallTimelineRow(
        entry: makeAnnotatedToolCallEntry(
          entryId: "call-newer",
          recordedAt: "2026-04-28T00:00:02Z",
          status: "completed",
          stopReason: "end_turn",
          sequence: 20
        )
      )
    )
    let olderRow = try #require(
      ToolCallTimelineRow(
        entry: makeAnnotatedToolCallEntry(
          entryId: "call-older",
          recordedAt: "2026-04-28T00:00:01Z",
          status: "failed",
          stopReason: "error",
          sequence: 10
        )
      )
    )

    let announcedRows = ToolCallTimelineView.orderedAnnouncementRows(
      previousStates: [
        newerRow.id: .started,
        olderRow.id: .started,
      ],
      rows: [newerRow, olderRow],
      liveAnnouncementRowIDs: [newerRow.id, olderRow.id],
      verboseAnnouncements: false
    )

    #expect(announcedRows.map(\.id) == [newerRow.id, olderRow.id])
  }

  @Test("Verbose announcements opt into per-state updates")
  func verboseAnnouncementsOptIntoPerStateUpdates() throws {
    let startedRow = try #require(
      ToolCallTimelineRow(
        entry: makeAnnotatedToolCallEntry(
          entryId: "call-started",
          recordedAt: "2026-04-28T00:00:00Z",
          status: "started",
          stopReason: nil
        )
      )
    )
    let completedRow = try #require(
      ToolCallTimelineRow(
        entry: makeAnnotatedToolCallEntry(
          entryId: "call-completed",
          recordedAt: "2026-04-28T00:00:01Z",
          status: "completed",
          stopReason: "end_turn"
        )
      )
    )

    #expect(
      ToolCallTimelineView.shouldAnnounceToolCallStatusChange(
        previousStatus: nil,
        row: startedRow,
        verboseAnnouncements: true
      )
    )
    #expect(
      ToolCallTimelineView.shouldAnnounceToolCallStatusChange(
        previousStatus: .started,
        row: completedRow,
        verboseAnnouncements: true
      )
    )
  }

  @Test("Viewport-visible rows intersect visible rect")
  func viewportVisibleRowsIntersectVisibleRect() {
    let visible = ToolCallTimelineView.viewportVisibleRowIDs(
      renderedRowIDs: ["row-1", "row-2", "row-3"],
      rowFrames: [
        "row-1": CGRect(x: 0, y: 10, width: 100, height: 30),
        "row-2": CGRect(x: 0, y: 120, width: 100, height: 30),
        "row-3": CGRect(x: 0, y: 260, width: 100, height: 30),
      ],
      visibleRect: CGRect(x: 0, y: 100, width: 500, height: 80)
    )

    #expect(visible == ["row-2"])
  }

  @Test("Viewport-visible rows ignore missing and non-rendered frame entries")
  func viewportVisibleRowsIgnoreMissingAndNonRenderedFrames() {
    let visible = ToolCallTimelineView.viewportVisibleRowIDs(
      renderedRowIDs: ["row-a", "row-b"],
      rowFrames: [
        "row-a": CGRect(x: 0, y: 10, width: 100, height: 30),
        "row-c": CGRect(x: 0, y: 20, width: 100, height: 30),
      ],
      visibleRect: CGRect(x: 0, y: 0, width: 500, height: 50)
    )

    #expect(visible == ["row-a"])
  }

  private func makeCanonicalEntry(
    entryId: String,
    recordedAt: String,
    kind: String,
    summary: String,
    event: [String: JSONValue]
  ) -> TimelineEntry {
    TimelineEntry(
      entryId: entryId,
      recordedAt: recordedAt,
      kind: kind,
      sessionId: "session-1",
      agentId: "acp-1",
      taskId: nil,
      summary: summary,
      payload: .object([
        "runtime": .string("acp"),
        "event": .object(event),
      ])
    )
  }

  private func makeAnnotatedToolCallEntry(
    entryId: String,
    recordedAt: String,
    status: String,
    stopReason: String?,
    sequence: UInt64 = 0
  ) -> TimelineEntry {
    TimelineEntry(
      entryId: entryId,
      recordedAt: recordedAt,
      kind: status == "started" ? "tool_invocation" : "tool_result",
      sessionId: "session-1",
      agentId: "acp-1",
      taskId: nil,
      summary: "Copilot \(status) Write",
      payload: .object([
        "runtime": .string("acp"),
        "event": .object([
          "type": .string(status == "started" ? "tool_invocation" : "tool_result"),
          "tool_name": .string("Write"),
          "invocation_id": .string(entryId),
          "is_error": .bool(status == "failed"),
          "stop_reason": stopReason.map(JSONValue.string) ?? .null,
        ]),
        "tool_call_timeline": .object([
          "tool_call_id": .string(entryId),
          "tool_name": .string("Write"),
          "status": .string(status),
          "acp_agent_id": .string("acp-1"),
          "agent_id": .string("copilot"),
          "agent_display_name": .string("Copilot"),
          "capability_tags": .array([.string("filesystem")]),
          "sequence": .number(Double(sequence)),
          "stop_reason": stopReason.map(JSONValue.string) ?? .null,
        ]),
      ])
    )
  }
}
