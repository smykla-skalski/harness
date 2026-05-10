import HarnessMonitorKit

extension SessionTimelineView {
  func traceTimelineBoundary(
    top: Bool,
    bottom: Bool,
    presentation: SessionTimelineSectionPresentation
  ) {
    HarnessMonitorTimelineTrace.info(
      "navigation.boundary top=\(top) bottom=\(bottom) \(timelineTraceSummary(presentation))"
    )
  }

  func traceTimelineEdge(
    _ actionName: String,
    limit: Int,
    advance: Int,
    presentation: SessionTimelineSectionPresentation
  ) {
    HarnessMonitorTimelineTrace.info(
      """
      navigation.edge \(actionName) limit=\(limit) advance=\(advance) \
      \(timelineTraceSummary(presentation))
      """
    )
  }

  func traceTimelineRequestSkip(
    _ actionName: String,
    reason: String,
    presentation: SessionTimelineSectionPresentation
  ) {
    HarnessMonitorTimelineTrace.info(
      "navigation.request_skip \(actionName) reason=\(reason) \(timelineTraceSummary(presentation))"
    )
  }

  func traceTimelineRequestDefer(
    _ actionName: String,
    presentation: SessionTimelineSectionPresentation
  ) {
    HarnessMonitorTimelineTrace.info(
      "navigation.request_defer \(actionName) reason=empty_loading \(timelineTraceSummary(presentation))"
    )
  }

  func traceTimelineOlderRequestStart(
    limit: Int,
    presentation: SessionTimelineSectionPresentation
  ) {
    HarnessMonitorTimelineTrace.info(
      "navigation.request_start older limit=\(limit) \(timelineTraceSummary(presentation))"
    )
  }

  func traceTimelineWindowRequestStart(
    _ actionName: String,
    request: TimelineWindowRequest,
    presentation: SessionTimelineSectionPresentation
  ) {
    HarnessMonitorTimelineTrace.info(
      """
      navigation.request_start \(actionName) \
      request=\(HarnessMonitorTimelineTrace.requestSummary(request)) \
      \(timelineTraceSummary(presentation))
      """
    )
  }

  func timelineTraceActionName(_ action: SessionTimelineWindowAction) -> String {
    switch action {
    case .older:
      "older"
    case .latest:
      "latest"
    case .newer:
      "newer"
    }
  }

  private func timelineTraceSummary(
    _ presentation: SessionTimelineSectionPresentation
  ) -> String {
    let navigation = presentation.navigation
    return
      """
      loaded=\(navigation.loadedCount) total=\(navigation.totalCount) \
      start=\(navigation.windowStart) end=\(navigation.windowEnd) \
      hasOlder=\(navigation.hasOlder) hasNewer=\(navigation.hasNewer) \
      loading=\(isTimelineLoading)
      """
  }
}
