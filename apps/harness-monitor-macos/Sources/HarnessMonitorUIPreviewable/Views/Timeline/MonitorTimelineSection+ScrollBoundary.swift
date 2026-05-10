extension SessionTimelineView {
  @MainActor
  func issueScroll(to targetID: String?) {
    timelineViewport.setAnchorID(targetID)
    issueScrollCommand(targetID)
  }

  func issueScrollCommand(_ targetID: String?) {
    guard let targetID else {
      currentTimelineScrollCommand = nil
      return
    }
    currentTimelineScrollCommandGeneration += 1
    currentTimelineScrollCommand = SessionTimelineScrollCommand(
      targetID: targetID,
      generation: currentTimelineScrollCommandGeneration
    )
  }

  func handleScrollBoundaryChange(
    from oldValue: SessionTimelineScrollBoundaryState,
    to newValue: SessionTimelineScrollBoundaryState,
    presentation: SessionTimelineSectionPresentation
  ) {
    let enteredTopEdge = newValue.enteredTopEdge(from: oldValue)
    let enteredBottomEdge = newValue.enteredBottomEdge(from: oldValue)
    if enteredTopEdge {
      requestNewerWindowIfNeeded(presentation, from: oldValue, to: newValue)
    }
    if enteredBottomEdge {
      requestOlderWindowIfNeeded(presentation, from: oldValue, to: newValue)
    }
  }
}
