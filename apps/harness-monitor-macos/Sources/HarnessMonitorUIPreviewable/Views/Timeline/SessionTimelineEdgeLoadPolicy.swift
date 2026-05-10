struct SessionTimelineEdgeLoadRetryInput: Equatable {
  let sessionID: String
  let pendingLoad: SessionTimelinePendingEdgeLoad?
  let isTimelineLoading: Bool
  let windowStart: Int
  let windowEnd: Int
  let loadedCount: Int
  let totalCount: Int
  let hasOlder: Bool
  let hasNewer: Bool
}

struct SessionTimelinePendingEdgeLoad: Equatable {
  let sessionID: String
  let action: SessionTimelineWindowAction
  let baselineWindowStart: Int
  let baselineWindowEnd: Int

  func didAdvance(
    sessionID currentSessionID: String,
    navigation: SessionTimelineWindowNavigation
  ) -> Bool {
    guard sessionID == currentSessionID else {
      return false
    }
    switch action {
    case .older:
      return navigation.windowEnd > baselineWindowEnd || !navigation.hasOlder
    case .latest:
      return false
    case .newer:
      return navigation.windowStart < baselineWindowStart || !navigation.hasNewer
    }
  }

  func isWaitingForFreshPresentation(
    sessionID currentSessionID: String,
    navigation: SessionTimelineWindowNavigation
  ) -> Bool {
    sessionID == currentSessionID
      && navigation.windowStart == baselineWindowStart
      && navigation.windowEnd == baselineWindowEnd
  }
}

struct SessionTimelineEdgeLoadContext {
  let navigation: SessionTimelineWindowNavigation
  let visibleRowCount: Int
  let viewportRowCapacity: Int
  let fallbackVisibleRowCount: Int
  let topEdgeBufferDeficitRows: Int
  let bottomEdgeBufferDeficitRows: Int

  init(
    navigation: SessionTimelineWindowNavigation,
    visibleRowCount: Int,
    viewportRowCapacity: Int = 0,
    fallbackVisibleRowCount: Int,
    topEdgeBufferDeficitRows: Int = 0,
    bottomEdgeBufferDeficitRows: Int = 0
  ) {
    self.navigation = navigation
    self.visibleRowCount = visibleRowCount
    self.viewportRowCapacity = viewportRowCapacity
    self.fallbackVisibleRowCount = fallbackVisibleRowCount
    self.topEdgeBufferDeficitRows = topEdgeBufferDeficitRows
    self.bottomEdgeBufferDeficitRows = bottomEdgeBufferDeficitRows
  }

  func bufferDeficitRows(for action: SessionTimelineWindowAction) -> Int {
    switch action {
    case .older:
      bottomEdgeBufferDeficitRows
    case .latest:
      0
    case .newer:
      topEdgeBufferDeficitRows
    }
  }
}

enum SessionTimelineEdgeLoadPolicy {
  static let minimumChunkLimit = 1
  static let maximumChunkLimit = SessionTimelineWindowNavigation.defaultLimit

  static func limit(
    for action: SessionTimelineWindowAction,
    context: SessionTimelineEdgeLoadContext,
    from oldValue: SessionTimelineScrollBoundaryState,
    to newValue: SessionTimelineScrollBoundaryState
  ) -> Int {
    let advance: Int
    let bufferDeficitRows: Int
    switch action {
    case .older:
      advance = newValue.bottomEdgeAdvance(from: oldValue)
      bufferDeficitRows = newValue.bottomEdgeBufferDeficitRows()
    case .newer:
      advance = newValue.topEdgeAdvance(from: oldValue)
      bufferDeficitRows = newValue.topEdgeBufferDeficitRows()
    case .latest:
      advance = 0
      bufferDeficitRows = 0
    }
    return limit(
      for: action,
      context: context,
      edgeAdvanceRows: advance,
      edgeBufferDeficitRows: bufferDeficitRows
    )
  }

  static func retryLimit(
    for action: SessionTimelineWindowAction,
    context: SessionTimelineEdgeLoadContext
  ) -> Int {
    limit(
      for: action,
      context: context,
      edgeAdvanceRows: 0,
      edgeBufferDeficitRows: context.bufferDeficitRows(for: action)
    )
  }

  private static func limit(
    for action: SessionTimelineWindowAction,
    context: SessionTimelineEdgeLoadContext,
    edgeAdvanceRows: Int,
    edgeBufferDeficitRows: Int
  ) -> Int {
    let remaining = remainingEvents(for: action, navigation: context.navigation)
    guard remaining > 0 else {
      return 0
    }
    let desiredLimit = max(
      minimumChunkLimit,
      max(0, edgeAdvanceRows),
      max(0, edgeBufferDeficitRows)
    )
    let boundedLimit = min(maximumChunkLimit, desiredLimit)
    return min(remaining, boundedLimit)
  }

  private static func remainingEvents(
    for action: SessionTimelineWindowAction,
    navigation: SessionTimelineWindowNavigation
  ) -> Int {
    switch action {
    case .older:
      max(0, navigation.totalCount - navigation.windowEnd)
    case .latest:
      0
    case .newer:
      max(0, navigation.windowStart)
    }
  }
}

extension SessionTimelineView {
  func edgeLoadRetryInput(
    for presentation: SessionTimelineSectionPresentation
  ) -> SessionTimelineEdgeLoadRetryInput {
    SessionTimelineEdgeLoadRetryInput(
      sessionID: sessionID,
      pendingLoad: currentPendingEdgeLoad,
      isTimelineLoading: isTimelineLoading || presentation.navigation.isLoading,
      windowStart: presentation.navigation.windowStart,
      windowEnd: presentation.navigation.windowEnd,
      loadedCount: presentation.navigation.loadedCount,
      totalCount: presentation.navigation.totalCount,
      hasOlder: presentation.navigation.hasOlder,
      hasNewer: presentation.navigation.hasNewer
    )
  }
}
