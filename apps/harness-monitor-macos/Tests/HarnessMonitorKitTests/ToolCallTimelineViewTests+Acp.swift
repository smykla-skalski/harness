import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
extension ToolCallTimelineViewTests {
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
    #expect(
      firstSection.rows.map(\.capabilityTags) == [
        ["filesystem", "terminal"],
        ["filesystem", "terminal"],
      ])
  }

  @Test("Section accessibility label explains capability tags")
  func sectionAccessibilityLabelExplainsCapabilityTags() {
    #expect(
      ToolCallTimelineView.sectionAccessibilityLabel(
        title: "Copilot",
        capabilityTags: ["filesystem", "terminal"]
      ) == "Copilot. Capabilities: filesystem, terminal."
    )
    #expect(
      ToolCallTimelineView.sectionAccessibilityLabel(
        title: "Copilot",
        capabilityTags: []
      ) == "Copilot"
    )
  }

  @Test("Timeline exposes polite live-region accessibility marker text")
  func timelineAccessibilityMarkerUsesPoliteLiveRegion() {
    #expect(ToolCallTimelineView.accessibilityStateMarkerText == "live-region=polite")
  }

  @Test("Rows with matching timestamps keep daemon sequence order")
  func rowsWithMatchingTimestampsKeepDaemonSequenceOrder() {
    let rows = ToolCallTimelineView.materialiseRows(
      from: makeEnrichedAcpEntries(
        acpID: "acp-a",
        agentID: "copilot",
        displayName: "Copilot",
        capabilityTags: ["filesystem"],
        events: [
          makeAcpEvent(
            recordedAt: "2026-04-28T00:00:00Z",
            sequence: 2,
            type: "tool_invocation",
            toolName: "Read",
            invocationID: "call-2"
          ),
          makeAcpEvent(
            recordedAt: "2026-04-28T00:00:00Z",
            sequence: 10,
            type: "tool_invocation",
            toolName: "Write",
            invocationID: "call-10"
          ),
        ]
      )
    )

    #expect(rows.map(\.id) == ["session-1::acp-a::call-10", "session-1::acp-a::call-2"])
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
}
