import HarnessMonitorKit
import SwiftUI

struct SessionCockpitTimelineSection: View {
  let sessionID: String
  let timeline: [TimelineEntry]
  let timelineWindow: TimelineWindowResponse?
  let decisions: [Decision]
  let isTimelineLoading: Bool
  let actionHandler: any DecisionActionHandler
  let loadWindow: @Sendable (TimelineWindowRequest) async -> Void

  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @State private var visibleAnchorID: String?
  @State private var scrollCommand: SessionTimelineScrollCommand?
  @State private var scrollCommandGeneration = 0
  @State private var pendingNavigationAfterLoad: SessionTimelinePendingNavigation?
  @State private var pendingNavigationGeneration = 0
  @State private var cachedPresentation = SessionTimelineSectionPresentation.empty
  @State private var cachedPresentationInput = SessionTimelinePresentationInput.empty
  @State private var cachedVisibilityStats = SessionTimelineVisibilityStats.empty

  private var contentIdentity: SessionTimelineContentIdentity {
    SessionTimelineContentIdentity(sessionID: sessionID)
  }

  var body: some View {
    let input = presentationInput
    ViewBodySignposter.measure("SessionCockpitTimelineSection") {
      content(for: cachedPresentation)
    }
    .onAppear {
      rebuildPresentationIfNeeded(for: input, force: true)
    }
    .onChange(of: input) { _, newInput in
      rebuildPresentationIfNeeded(for: newInput)
    }
  }

  private var presentationInput: SessionTimelinePresentationInput {
    SessionTimelinePresentationInput(
      sessionID: sessionID,
      timelineCount: timeline.count,
      firstTimelineEntryID: timeline.first?.entryId,
      firstTimelineRecordedAt: timeline.first?.recordedAt,
      lastTimelineEntryID: timeline.last?.entryId,
      lastTimelineRecordedAt: timeline.last?.recordedAt,
      timelineWindowRevision: timelineWindow?.revision,
      timelineWindowStart: timelineWindow?.windowStart,
      timelineWindowEnd: timelineWindow?.windowEnd,
      timelineWindowHasOlder: timelineWindow?.hasOlder ?? false,
      timelineWindowHasNewer: timelineWindow?.hasNewer ?? false,
      decisionCount: decisions.count,
      firstDecisionID: decisions.first?.id,
      lastDecisionID: decisions.last?.id,
      isTimelineLoading: isTimelineLoading,
      reduceMotion: reduceMotion,
      dateTimeConfiguration: dateTimeConfiguration
    )
  }

  @MainActor
  private func rebuildPresentationIfNeeded(
    for input: SessionTimelinePresentationInput,
    force: Bool = false
  ) {
    guard force || cachedPresentationInput != input else {
      return
    }
    cachedPresentation = SessionTimelineSectionPresentation(
      sessionID: sessionID,
      timeline: timeline,
      timelineWindow: timelineWindow,
      decisions: decisions,
      isTimelineLoading: isTimelineLoading,
      reduceMotion: reduceMotion,
      dateTimeConfiguration: dateTimeConfiguration
    )
    cachedPresentationInput = input
    rebuildVisibilityStats(
      viewportStats: SessionTimelineTableViewportStats.initial(
        estimatedVisibleRows: cachedPresentation.fallbackVisibleRowCount,
        totalRows: cachedPresentation.rows.count
      )
    )
  }

  private func content(for presentation: SessionTimelineSectionPresentation) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      Text("Timeline")
        .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
        .accessibilityAddTraits(.isHeader)

      if presentation.showsEmptyState {
        SessionCockpitEmptyStateRow(section: .timeline)
      } else {
        timelineSurface(for: presentation)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onAppear {
      reconcileTimelineAnchor(with: presentation.scrollNodeIDs)
      requestLatestWindowIfNeeded(presentation)
    }
    .onChange(of: sessionID) { _, _ in
      visibleAnchorID = nil
      scrollCommand = nil
      pendingNavigationAfterLoad = nil
      requestLatestWindow()
    }
    .onChange(of: presentation.scrollNodeIDs) { _, ids in
      reconcileTimelineAnchor(with: ids)
      completePendingNavigationIfNeeded(presentation)
    }
  }

  private func timelineSurface(for presentation: SessionTimelineSectionPresentation) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingLG) {
      if presentation.navigation.showsNavigation {
        let anchorID = navigationAnchorID
        SessionTimelineNavigationControls(
          navigation: presentation.navigation,
          canScrollOlder: presentation.canScrollOlder(from: anchorID),
          canScrollNewer: presentation.canScrollNewer(from: anchorID),
          visibilityStats: cachedVisibilityStats,
          performAction: { action in
            performNavigationAction(action, presentation: presentation)
          }
        )
      }

      timelineScrollContent(for: presentation)
    }
    .padding(HarnessMonitorTheme.spacingLG)
    .background {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusLG, style: .continuous)
        .fill(.primary.opacity(0.035))
        .overlay {
          RoundedRectangle(
            cornerRadius: HarnessMonitorTheme.cornerRadiusLG,
            style: .continuous
          )
          .stroke(HarnessMonitorTheme.controlBorder.opacity(0.55), lineWidth: 1)
        }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func timelineScrollContent(
    for presentation: SessionTimelineSectionPresentation
  ) -> some View {
    Group {
      if presentation.rows.isEmpty {
        timelinePlaceholderContent(for: presentation)
      } else {
        GeometryReader { geo in
          SessionTimelineTableView(
            columnWidth: geo.size.width,
            rows: presentation.rows,
            scrollCommand: scrollCommand,
            actionHandler: actionHandler,
            viewportStatsChanged: { viewportStats in
              updateVisibleAnchor(viewportStats.anchorRowID)
              rebuildVisibilityStats(viewportStats: viewportStats)
            },
            scrollBoundaryChanged: { oldValue, newValue in
              handleScrollBoundaryChange(
                from: oldValue,
                to: newValue,
                presentation: presentation
              )
            }
          )
        }
      }
    }
    .frame(height: presentation.viewportHeight)
  }

  private func timelinePlaceholderContent(
    for presentation: SessionTimelineSectionPresentation
  ) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        SessionTimelineCards(
          rows: [],
          placeholderCount: presentation.placeholderCount,
          shimmerPhase: SessionTimelinePlaceholderShimmer.restingPhase,
          showsShimmer: presentation.shouldAnimatePlaceholders,
          actionHandler: actionHandler
        )
      }
      .id(contentIdentity)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .scrollIndicators(.visible)
    .scrollBounceBehavior(.always, axes: .vertical)
    .scrollClipDisabled(false)
  }

  private func rebuildVisibilityStats(
    viewportStats: SessionTimelineTableViewportStats
  ) {
    let stats = SessionTimelineVisibilityStats(
      visibleRowCount: viewportStats.visibleRowCount,
      renderedRowCount: viewportStats.renderedRowCount,
      loadedEventCount: cachedPresentation.navigation.loadedCount,
      totalEventCount: cachedPresentation.navigation.totalCount
    )
    if cachedVisibilityStats != stats {
      cachedVisibilityStats = stats
    }
  }
}

extension SessionCockpitTimelineSection {
  private var navigationAnchorID: String? {
    visibleAnchorID ?? scrollCommand?.targetID
  }

  private func requestLatestWindowIfNeeded(_ presentation: SessionTimelineSectionPresentation) {
    guard !presentation.hasLatestWindow else { return }
    requestLatestWindow()
  }

  private func requestLatestWindow() {
    Task { await loadWindow(.latest(limit: SessionTimelineWindowNavigation.defaultLimit)) }
  }

  private func requestOlderWindowIfNeeded(_ presentation: SessionTimelineSectionPresentation) {
    requestWindowIfNeeded(for: .older, presentation: presentation)
  }

  private func requestNewerWindowIfNeeded(_ presentation: SessionTimelineSectionPresentation) {
    requestWindowIfNeeded(for: .newer, presentation: presentation)
  }

  private func requestWindowIfNeeded(
    for action: SessionTimelineWindowAction,
    presentation: SessionTimelineSectionPresentation
  ) {
    guard !isTimelineLoading, let request = presentation.navigation.request(for: action) else {
      return
    }
    Task { await loadWindow(request) }
  }

  private func performNavigationAction(
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
          let request = TimelineWindowRequest.latest(
            limit: SessionTimelineWindowNavigation.defaultLimit
          )
          markPendingNavigation(.latest, request: request)
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

  private func loadWindowBeforeNavigationIfNeeded(
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
    markPendingNavigation(action, request: request)
    await loadWindow(request)
    return true
  }

  @MainActor
  private func markPendingNavigation(
    _ action: SessionTimelineWindowAction,
    request: TimelineWindowRequest
  ) {
    pendingNavigationGeneration += 1
    pendingNavigationAfterLoad = SessionTimelinePendingNavigation(
      action: action,
      request: request,
      sessionID: sessionID,
      generation: pendingNavigationGeneration
    )
  }

  @MainActor
  private func cancelPendingNavigation() {
    pendingNavigationAfterLoad = nil
  }

  @MainActor
  private func completePendingNavigationIfNeeded(
    _ presentation: SessionTimelineSectionPresentation
  ) {
    guard let pending = pendingNavigationAfterLoad,
      pending.isSatisfied(sessionID: sessionID, navigation: presentation.navigation),
      !presentation.scrollNodeIDs.isEmpty
    else {
      return
    }
    pendingNavigationAfterLoad = nil
    issueScroll(to: nextTarget(for: pending.action, presentation: presentation))
  }

  private func nextTarget(
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

  private func scroll(to targetID: String?) async {
    guard let targetID else { return }
    await MainActor.run { issueScroll(to: targetID) }
  }

  private func reconcileTimelineAnchor(with ids: [String]) {
    guard !ids.isEmpty else {
      visibleAnchorID = nil
      scrollCommand = nil
      return
    }
    guard let anchorID = navigationAnchorID else {
      visibleAnchorID = ids.first
      issueScrollCommand(ids.first)
      return
    }
    if !ids.contains(anchorID) {
      visibleAnchorID = ids.first
      issueScrollCommand(ids.first)
    }
  }

  private func updateVisibleAnchor(_ anchorID: String?) {
    guard let anchorID, visibleAnchorID != anchorID else { return }
    visibleAnchorID = anchorID
  }

  @MainActor
  private func issueScroll(to targetID: String?) {
    visibleAnchorID = targetID
    issueScrollCommand(targetID)
  }

  private func issueScrollCommand(_ targetID: String?) {
    guard let targetID else {
      scrollCommand = nil
      return
    }
    scrollCommandGeneration += 1
    scrollCommand = SessionTimelineScrollCommand(
      targetID: targetID,
      generation: scrollCommandGeneration
    )
  }

  private func handleScrollBoundaryChange(
    from oldValue: SessionTimelineScrollBoundaryState,
    to newValue: SessionTimelineScrollBoundaryState,
    presentation: SessionTimelineSectionPresentation
  ) {
    if newValue.enteredTopEdge(from: oldValue) {
      requestNewerWindowIfNeeded(presentation)
    }
    if newValue.enteredBottomEdge(from: oldValue) {
      requestOlderWindowIfNeeded(presentation)
    }
  }
}

#Preview("Timeline") {
  SessionCockpitTimelineSection.richPreview
}
