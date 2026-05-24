import Testing

extension SessionWindowFlowTests {
  @Test("High-volume session text renders dynamic values verbatim")
  func highVolumeSessionTextRendersDynamicValuesVerbatim() throws {
    let timelineSource = try previewableSourceFile(
      named: "Views/Timeline/SessionTimelineCards.swift"
    )
    let taskLaneSource = try previewableSourceFile(
      named: "Views/Sessions/SessionTaskLaneViews.swift"
    )
    let agentSummarySource = try previewableSourceFile(
      named: "Views/Sessions/SessionAgentSummaryCard.swift"
    )
    let headerSource = try previewableSourceFile(
      named: "Views/Sessions/SessionCockpitHeaderCard.swift"
    )

    #expect(timelineSource.contains("Text(verbatim: row.timestampLabel)"))
    #expect(timelineSource.contains("Text(verbatim: node.title)"))
    #expect(timelineSource.contains("Text(verbatim: node.sourceLabel)"))
    #expect(timelineSource.contains("Text(verbatim: detail)"))
    #expect(taskLaneSource.contains("Text(verbatim: task.title)"))
    #expect(taskLaneSource.contains("Text(verbatim: task.assignmentStateTitle)"))
    #expect(agentSummarySource.contains("Text(verbatim: agent.name)"))
    #expect(agentSummarySource.contains("Text(verbatim: metadataLine)"))
    #expect(headerSource.contains("Text(verbatim: detail.session.displayTitle)"))
    #expect(headerSource.contains("Text(verbatim: detail.session.context)"))
    #expect(headerSource.contains("Text(verbatim: value)"))
  }
}
