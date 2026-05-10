import HarnessMonitorKit
import SwiftUI

extension SessionTimelineView {
  // navigationAnchorID is read only from non-body code paths (async Tasks
  // and onChange/onAppear closures). Reading the viewport's unobserved current
  // anchor here does NOT register a SwiftUI body dependency on the model and
  // does not re-introduce the per-scroll re-eval loop.
  var navigationAnchorID: String? {
    timelineViewport.currentVisibleAnchorID() ?? currentTimelineScrollCommand?.targetID
  }

  func requestLatestWindowIfNeeded(_ presentation: SessionTimelineSectionPresentation) {
    guard !presentation.hasLatestWindow else { return }
    requestLatestWindow()
  }

  func requestLatestWindow() {
    Task {
      await loadWindow(.latest(limit: preferredTimelineWindowLimit()))
    }
  }

  func requestOlderWindowIfNeeded(_ presentation: SessionTimelineSectionPresentation) {
    requestOlderWindowIfNeeded(presentation, limit: presentation.navigation.limit)
  }

  @discardableResult
  func requestOlderWindowIfNeeded(
    _ presentation: SessionTimelineSectionPresentation,
    from oldValue: SessionTimelineScrollBoundaryState,
    to newValue: SessionTimelineScrollBoundaryState
  ) -> Bool {
    let limit = SessionTimelineEdgeLoadPolicy.limit(
      for: .older,
      context: edgeLoadContext(for: presentation),
      from: oldValue,
      to: newValue
    )
    return requestOlderWindowIfNeeded(presentation, limit: limit)
  }

  @discardableResult
  func requestOlderWindowIfNeeded(
    _ presentation: SessionTimelineSectionPresentation,
    limit: Int
  ) -> Bool {
    guard limit > 0, presentation.navigation.hasOlder else {
      clearPendingEdgeLoadIfNeeded(.older)
      return false
    }
    guard !isTimelineLoading else {
      markPendingEdgeLoad(.older, presentation: presentation)
      return false
    }
    clearPendingEdgeLoadIfNeeded(.older)
    Task {
      await loadOlderTimelineChunk(limit: limit)
      await MainActor.run {
        markPendingEdgeLoad(.older, presentation: presentation)
      }
    }
    return true
  }

  @discardableResult
  func requestNewerWindowIfNeeded(
    _ presentation: SessionTimelineSectionPresentation,
    from oldValue: SessionTimelineScrollBoundaryState,
    to newValue: SessionTimelineScrollBoundaryState
  ) -> Bool {
    let limit = SessionTimelineEdgeLoadPolicy.limit(
      for: .newer,
      context: edgeLoadContext(for: presentation),
      from: oldValue,
      to: newValue
    )
    return requestWindowIfNeeded(
      for: .newer,
      presentation: presentation,
      limit: limit,
      deferIfLoading: true
    )
  }

  @discardableResult
  func requestWindowIfNeeded(
    for action: SessionTimelineWindowAction,
    presentation: SessionTimelineSectionPresentation,
    limit: Int? = nil,
    deferIfLoading: Bool = false
  ) -> Bool {
    if let limit, limit <= 0 {
      clearPendingEdgeLoadIfNeeded(action)
      return false
    }
    guard let request = presentation.navigation.request(for: action, limit: limit) else {
      clearPendingEdgeLoadIfNeeded(action)
      return false
    }
    guard !isTimelineLoading else {
      if deferIfLoading {
        markPendingEdgeLoad(action, presentation: presentation)
      }
      return false
    }
    clearPendingEdgeLoadIfNeeded(action)
    Task {
      await loadWindow(request)
      if deferIfLoading {
        await MainActor.run {
          markPendingEdgeLoad(action, presentation: presentation)
        }
      }
    }
    return true
  }

  @MainActor
  func retryPendingEdgeLoadIfNeeded(for presentation: SessionTimelineSectionPresentation) {
    guard let pendingLoad = currentPendingEdgeLoad, !isTimelineLoading else {
      return
    }
    guard pendingLoad.didAdvance(sessionID: sessionID, navigation: presentation.navigation) else {
      if pendingLoad.isWaitingForFreshPresentation(
        sessionID: sessionID,
        navigation: presentation.navigation
      ) {
        return
      }
      currentPendingEdgeLoad = nil
      return
    }
    let action = pendingLoad.action
    let isStillNearEdge =
      switch action {
      case .older:
        timelineViewport.isNearBottomScrollEdge()
      case .latest:
        false
      case .newer:
        timelineViewport.isNearTopScrollEdge()
      }
    guard isStillNearEdge else {
      currentPendingEdgeLoad = nil
      return
    }
    let limit = SessionTimelineEdgeLoadPolicy.retryLimit(
      for: action,
      context: edgeLoadContext(for: presentation)
    )
    switch action {
    case .older:
      requestOlderWindowIfNeeded(presentation, limit: limit)
    case .latest:
      currentPendingEdgeLoad = nil
    case .newer:
      requestWindowIfNeeded(
        for: .newer,
        presentation: presentation,
        limit: limit,
        deferIfLoading: true
      )
    }
  }

  @MainActor
  private func markPendingEdgeLoad(
    _ action: SessionTimelineWindowAction,
    presentation: SessionTimelineSectionPresentation
  ) {
    currentPendingEdgeLoad = SessionTimelinePendingEdgeLoad(
      sessionID: sessionID,
      action: action,
      baselineWindowStart: presentation.navigation.windowStart,
      baselineWindowEnd: presentation.navigation.windowEnd
    )
  }

  @MainActor
  private func clearPendingEdgeLoadIfNeeded(_ action: SessionTimelineWindowAction) {
    if currentPendingEdgeLoad?.action == action {
      currentPendingEdgeLoad = nil
    }
  }

  private func edgeLoadContext(
    for presentation: SessionTimelineSectionPresentation
  ) -> SessionTimelineEdgeLoadContext {
    SessionTimelineEdgeLoadContext(
      navigation: presentation.navigation,
      visibleRowCount: timelineViewport.currentVisibleRowCount(),
      viewportRowCapacity: timelineViewport.currentViewportRowCapacity(),
      fallbackVisibleRowCount: presentation.fallbackVisibleRowCount
    )
  }

  func performNavigationAction(
    _ action: SessionTimelineWindowAction,
    presentation: SessionTimelineSectionPresentation
  ) {
    Task {
      switch action {
      case .older:
        if await loadWindowBeforeNavigationIfNeeded(.older, presentation: presentation) {
          return
        }
        cancelPendingNavigation()
        await scroll(to: nextTarget(for: .older, presentation: presentation))
      case .latest:
        if !presentation.hasLatestWindow || presentation.navigation.hasNewer {
          let request = TimelineWindowRequest.latest(limit: preferredTimelineWindowLimit())
          markPendingNavigation(
            .latest,
            request: request,
            baselineWindowStart: presentation.navigation.windowStart
          )
          await loadWindow(request)
          return
        }
        cancelPendingNavigation()
        await scroll(to: nextTarget(for: .latest, presentation: presentation))
      case .newer:
        if await loadWindowBeforeNavigationIfNeeded(.newer, presentation: presentation) {
          return
        }
        cancelPendingNavigation()
        await scroll(to: nextTarget(for: .newer, presentation: presentation))
      }
    }
  }

  func loadWindowBeforeNavigationIfNeeded(
    _ action: SessionTimelineWindowAction,
    presentation: SessionTimelineSectionPresentation
  ) async -> Bool {
    let shouldLoad =
      switch action {
      case .older:
        presentation.shouldLoadOlderBeforeStepping(from: navigationAnchorID)
      case .latest:
        false
      case .newer:
        presentation.nextNewerNodeID(from: navigationAnchorID) == nil
          && presentation.navigation.hasNewer
      }
    guard shouldLoad, let request = presentation.navigation.request(for: action) else {
      return false
    }
    markPendingNavigation(
      action,
      request: request,
      baselineWindowStart: presentation.navigation.windowStart
    )
    await loadWindow(request)
    return true
  }

  @MainActor
  func markPendingNavigation(
    _ action: SessionTimelineWindowAction,
    request: TimelineWindowRequest,
    baselineWindowStart: Int
  ) {
    currentPendingNavigationGeneration += 1
    currentPendingNavigation = SessionTimelinePendingNavigation(
      action: action,
      request: request,
      sessionID: sessionID,
      generation: currentPendingNavigationGeneration,
      baselineWindowStart: baselineWindowStart
    )
  }

  @MainActor
  func cancelPendingNavigation() {
    currentPendingNavigation = nil
  }

  @MainActor
  func completePendingNavigationIfNeeded(
    _ presentation: SessionTimelineSectionPresentation
  ) {
    guard let pending = currentPendingNavigation,
      pending.isSatisfied(sessionID: sessionID, navigation: presentation.navigation),
      !presentation.scrollNodeIDs.isEmpty
    else {
      return
    }
    currentPendingNavigation = nil
    issueScroll(to: nextTarget(for: pending.action, presentation: presentation))
  }

  func nextTarget(
    for action: SessionTimelineWindowAction,
    presentation: SessionTimelineSectionPresentation
  ) -> String? {
    switch action {
    case .older:
      presentation.nextOlderNodeID(from: navigationAnchorID) ?? presentation.scrollNodeIDs.last
    case .latest:
      presentation.scrollNodeIDs.first
    case .newer:
      presentation.nextNewerNodeID(from: navigationAnchorID) ?? presentation.scrollNodeIDs.first
    }
  }

  func scroll(to targetID: String?) async {
    guard let targetID else { return }
    await MainActor.run { issueScroll(to: targetID) }
  }

  func reconcileTimelineAnchor(with ids: [String]) {
    guard !ids.isEmpty else {
      timelineViewport.setAnchorID(nil)
      currentTimelineScrollCommand = nil
      return
    }
    guard let anchorID = navigationAnchorID else {
      timelineViewport.setAnchorID(ids.first)
      issueScrollCommand(ids.first)
      return
    }
    if !ids.contains(anchorID) {
      // Explicit cursor-window loads and revision-refresh fallbacks can still
      // replace the loaded slice and drop the previous anchor. In that case the
      // coordinator already restored the viewport as far as possible, and any
      // explicit navigation follow-up is handled by pending navigation. Forcing
      // a new scroll to the first row here snaps the user back toward the top.
      timelineViewport.setAnchorID(ids.first)
      currentTimelineScrollCommand = nil
    }
  }

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
    if newValue.enteredTopEdge(from: oldValue) {
      requestNewerWindowIfNeeded(presentation, from: oldValue, to: newValue)
    }
    if newValue.enteredBottomEdge(from: oldValue) {
      requestOlderWindowIfNeeded(presentation, from: oldValue, to: newValue)
    }
  }

  @MainActor
  func hydrateFilters(for input: SessionTimelineFilterHydrationInput) {
    let nextFilters = SessionTimelineFilterPersistenceResolver.hydrate(
      mode: currentFilterPersistenceMode,
      input: input
    )
    if currentFilters != nextFilters {
      currentFilters = nextFilters
    }
  }

  @MainActor
  func persistFilters(_ state: SessionTimelineFilterState) {
    let persisted = SessionTimelineFilterPersistenceResolver.persist(
      mode: currentFilterPersistenceMode,
      state: state,
      sessionID: sessionID,
      appStateRawValue: currentAppStoredFilterStateRawValue,
      sceneRegistryRawValue: currentSceneStoredFilterRegistryRawValue
    )
    if currentAppStoredFilterStateRawValue != persisted.appStateRawValue {
      currentAppStoredFilterStateRawValue = persisted.appStateRawValue
      SessionTimelineFilterDefaults.writeAppStateRawValue(persisted.appStateRawValue)
    }
    if currentSceneStoredFilterRegistryRawValue != persisted.sceneRegistryRawValue {
      currentSceneStoredFilterRegistryRawValue = persisted.sceneRegistryRawValue
    }
  }
}

struct SessionTimelineFilteredEmptyState: View {
  @Binding var filters: SessionTimelineFilterState

  var body: some View {
    VStack(spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: "line.3.horizontal.decrease.circle")
        .font(.title2)
        .foregroundStyle(.secondary)
      Text("No timeline items match these filters")
        .scaledFont(.body.weight(.semibold))
      Button("Clear filters") {
        filters.clear()
      }
      .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(HarnessMonitorTheme.spacingLG)
  }
}
