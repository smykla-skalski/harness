import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

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

    #expect(row.id == "call-1")
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
        ])
      ])
    )

    let row = try #require(ToolCallTimelineView.materialiseRows(from: [entry]).first)

    #expect(row.id == "legacy-event-1")
    #expect(row.title == "Bash")
    #expect(row.status == .started)
  }

  @Test("ACP rows keep precomputed attribution and group consecutive ACP agents")
  func acpRowsKeepPrecomputedAttributionAndGroupConsecutiveAcpAgents() throws {
    let entries =
      makeEnrichedAcpEntries(
        acpID: "acp-a",
        agentID: "copilot",
        displayName: "Copilot",
        capabilityTags: ["filesystem", "terminal"],
        events: [
          makeAcpEvent(
            recordedAt: "2026-04-28T00:00:04Z",
            sequence: 4,
            type: "tool_result",
            toolName: "Write",
            invocationID: "call-a-2"
          ),
          makeAcpEvent(
            recordedAt: "2026-04-28T00:00:03Z",
            sequence: 3,
            type: "tool_invocation",
            toolName: "Read",
            invocationID: "call-a-1"
          ),
        ]
      )
      + makeEnrichedAcpEntries(
        acpID: "acp-b",
        agentID: "claude",
        displayName: "Claude",
        capabilityTags: ["search"],
        events: [
          makeAcpEvent(
            recordedAt: "2026-04-28T00:00:02Z",
            sequence: 2,
            type: "tool_result",
            toolName: "Search",
            invocationID: "call-b-1"
          )
        ]
      )
      + makeEnrichedAcpEntries(
        acpID: "acp-a",
        agentID: "copilot",
        displayName: "Copilot",
        capabilityTags: ["filesystem", "terminal"],
        events: [
          makeAcpEvent(
            recordedAt: "2026-04-28T00:00:01Z",
            sequence: 1,
            type: "tool_result_error",
            toolName: "Write",
            invocationID: "call-a-0",
            isError: true
          )
        ]
      )

    let presentation = ToolCallTimelineView.materialisePresentation(from: entries)
    let firstSection = try #require(presentation.sections.first)

    #expect(presentation.sections.map(\.acpAgentID) == ["acp-a", "acp-b", "acp-a"])
    #expect(presentation.sections.map { $0.rows.count } == [2, 1, 1])
    #expect(firstSection.agentDisplayName == "Copilot")
    #expect(firstSection.capabilityTags == ["filesystem", "terminal"])
    #expect(firstSection.rows.map(\.agentDisplayName) == ["Copilot", "Copilot"])
    #expect(firstSection.rows.map(\.capabilityTags) == [
      ["filesystem", "terminal"],
      ["filesystem", "terminal"],
    ])
  }

  @Test("Duplicate tool call ids drop one deterministically")
  func duplicateToolCallIDsDropOneDeterministically() throws {
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

    #expect(presentation.duplicateToolCallIDs == ["call-dup"])
    #expect(presentation.rows.count == 1)
    #expect(row.id == "call-dup")
    #expect(row.detail == "copilot invoked Bash again")
  }

  @Test("Stop reason and terminal states drive the default announcement policy")
  func stopReasonAndTerminalStatesDriveTheDefaultAnnouncementPolicy() throws {
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

    #expect(startedRow.liveRegion == nil)
    #expect(completedRow.liveRegion == .polite)
    #expect(failedRow.liveRegion == .polite)
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

  private func makeEnrichedAcpEntries(
    acpID: String,
    agentID: String,
    displayName: String,
    capabilityTags: [String],
    events: [AcpConversationEvent]
  ) -> [TimelineEntry] {
    AcpEventBatchPayload(
      acpId: acpID,
      sessionId: "session-1",
      rawCount: events.count,
      events: events
    ).timelineEntries(
      fallbackRecordedAt: "2026-04-28T00:00:10Z",
      toolCallMetadata: AcpToolCallTimelineMetadata(
        acpAgentId: acpID,
        agentId: agentID,
        displayName: displayName,
        capabilityTags: capabilityTags
      )
    )
  }

  private func makeAcpEvent(
    recordedAt: String,
    sequence: UInt64,
    type: String,
    toolName: String,
    invocationID: String,
    isError: Bool = false
  ) -> AcpConversationEvent {
    var event: [String: JSONValue] = [
      "type": .string(type),
      "tool_name": .string(toolName),
      "invocation_id": .string(invocationID),
    ]
    if isError {
      event["is_error"] = .bool(true)
    }
    return AcpConversationEvent(
      timestamp: recordedAt,
      sequence: sequence,
      kind: .object(event),
      agent: toolName.lowercased(),
      sessionId: "session-1"
    )
  }

  private func makeAnnotatedToolCallEntry(
    entryId: String,
    recordedAt: String,
    status: String,
    stopReason: String?
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
          "stop_reason": stopReason.map(JSONValue.string) ?? .null,
        ]),
      ])
    )
  }
}
