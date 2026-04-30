import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Session cockpit timeline section")
@MainActor
struct SessionCockpitTimelineSectionTests {
  @Test("Cockpit attribution headers group consecutive ACP agent rows")
  func cockpitAttributionHeadersGroupConsecutiveAcpAgentRows() {
    let entries = [
      makeTimelineEntry(
        entryID: "row-1",
        acpAgentID: "acp-a",
        displayName: "Copilot",
        capabilityTags: ["filesystem", "terminal"]
      ),
      makeTimelineEntry(
        entryID: "row-2",
        acpAgentID: "acp-a",
        displayName: "Copilot",
        capabilityTags: ["filesystem", "terminal"]
      ),
      makeTimelineEntry(entryID: "row-3", acpAgentID: nil, displayName: nil),
      makeTimelineEntry(
        entryID: "row-4",
        acpAgentID: "acp-b",
        displayName: "Claude",
        capabilityTags: ["search"]
      ),
    ]

    let presentation = SessionCockpitTimelineSection.materialisePresentation(from: entries)

    #expect(presentation.sections.count == 3)
    #expect(
      presentation.sections.map(\.acpAgentID) == ["acp-a", nil, "acp-b"]
    )
    #expect(
      presentation.sections.map { $0.entries.map(\.entryId) } == [
        ["row-1", "row-2"],
        ["row-3"],
        ["row-4"],
      ]
    )
    #expect(presentation.sections.map(\.showsHeader) == [true, false, true])
    #expect(presentation.sections[0].capabilityTags == ["filesystem", "terminal"])
    #expect(presentation.sections[2].capabilityTags == ["search"])
  }

  @Test("Cockpit materialisation keeps row identity and order")
  func cockpitMaterialisationKeepsRowIdentityAndOrder() {
    let entries = [
      makeTimelineEntry(entryID: "row-a", acpAgentID: "acp-a", displayName: "Copilot"),
      makeTimelineEntry(entryID: "row-b", acpAgentID: "acp-b", displayName: "Claude"),
      makeTimelineEntry(entryID: "row-c", acpAgentID: "acp-a", displayName: "Copilot"),
    ]

    let presentation = SessionCockpitTimelineSection.materialisePresentation(from: entries)
    let flattenedIDs = presentation.sections.flatMap { $0.entries.map(\.entryId) }

    #expect(flattenedIDs == entries.map(\.entryId))
  }

  @Test("Missing display name suppresses attribution header")
  func missingDisplayNameSuppressesAttributionHeader() {
    let entries = [
      makeTimelineEntry(
        entryID: "row-1",
        acpAgentID: "acp-a",
        displayName: nil,
        capabilityTags: ["filesystem"]
      )
    ]

    let presentation = SessionCockpitTimelineSection.materialisePresentation(from: entries)
    #expect(presentation.sections.count == 1)
    let section = presentation.sections[0]

    #expect(section.acpAgentID == "acp-a")
    #expect(section.showsHeader == false)
  }

  private func makeTimelineEntry(
    entryID: String,
    acpAgentID: String?,
    displayName: String?,
    capabilityTags: [String] = []
  ) -> TimelineEntry {
    var metadata: [String: JSONValue] = [:]
    if let acpAgentID {
      metadata["acp_agent_id"] = .string(acpAgentID)
    }
    if let displayName {
      metadata["agent_display_name"] = .string(displayName)
    }
    metadata["capability_tags"] = .array(capabilityTags.map(JSONValue.string))
    metadata["tool_call_id"] = .string("call-\(entryID)")
    metadata["tool_name"] = .string("Read")
    metadata["status"] = .string("started")

    let payload: JSONValue =
      metadata.isEmpty
      ? .object(["event": .object(["type": .string("status")])])
      : .object([
        "event": .object([
          "type": .string("tool_invocation"),
          "invocation_id": .string("call-\(entryID)"),
        ]),
        "tool_call_timeline": .object(metadata),
      ])

    return TimelineEntry(
      entryId: entryID,
      recordedAt: "2026-04-30T00:00:00Z",
      kind: metadata.isEmpty ? "status" : "tool_invocation",
      sessionId: "session-1",
      agentId: "agent-1",
      taskId: nil,
      summary: "summary-\(entryID)",
      payload: payload
    )
  }
}
