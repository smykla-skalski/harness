struct SessionTimelineEdgeLoadRetryInput: Equatable {
  let sessionID: String
  let pendingAction: SessionTimelineWindowAction?
  let isTimelineLoading: Bool
  let windowStart: Int
  let windowEnd: Int
  let loadedCount: Int
  let totalCount: Int
  let hasOlder: Bool
  let hasNewer: Bool
}

struct SessionTimelineEdgeLoadContext {
  let navigation: SessionTimelineWindowNavigation
  let visibleRowCount: Int
  let fallbackVisibleRowCount: Int
}

enum SessionTimelineEdgeLoadPolicy {
  static let minimumChunkLimit = 4
  static let maximumChunkLimit = SessionTimelineWindowNavigation.defaultLimit

  static func limit(
    for action: SessionTimelineWindowAction,
    context: SessionTimelineEdgeLoadContext,
    from oldValue: SessionTimelineScrollBoundaryState,
    to newValue: SessionTimelineScrollBoundaryState
  ) -> Int {
    let advance: Int
    switch action {
    case .older:
      advance = newValue.bottomEdgeAdvance(from: oldValue)
    case .newer:
      advance = newValue.topEdgeAdvance(from: oldValue)
    case .latest:
      advance = 0
    }
    return limit(
      for: action,
      context: context,
      edgeAdvanceRows: advance
    )
  }

  static func retryLimit(
    for action: SessionTimelineWindowAction,
    context: SessionTimelineEdgeLoadContext
  ) -> Int {
    limit(
      for: action,
      context: context,
      edgeAdvanceRows: 0
    )
  }

  private static func limit(
    for action: SessionTimelineWindowAction,
    context: SessionTimelineEdgeLoadContext,
    edgeAdvanceRows: Int
  ) -> Int {
    let remaining = remainingEvents(for: action, navigation: context.navigation)
    guard remaining > 0 else {
      return 0
    }
    let visibleRows = max(1, context.visibleRowCount, context.fallbackVisibleRowCount)
    let desiredLimit =
      visibleRows + SessionTimelineScrollBoundaryState.triggerBufferRowCount
      + max(0, edgeAdvanceRows)
    let boundedLimit = max(
      minimumChunkLimit,
      min(maximumChunkLimit, desiredLimit)
    )
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
      pendingAction: currentPendingEdgeLoadAction,
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
