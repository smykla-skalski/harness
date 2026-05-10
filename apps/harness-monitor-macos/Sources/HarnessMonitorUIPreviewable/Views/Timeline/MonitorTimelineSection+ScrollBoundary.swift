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

  // Reads cachedPresentation from @State so the table-view callbacks can
  // be assigned as stable method references.
  func handleScrollBoundaryChange(
    from oldValue: SessionTimelineScrollBoundaryState,
    to newValue: SessionTimelineScrollBoundaryState
  ) {
    let presentation = cachedPresentation
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
