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
  @State private var scrollTargetID: String?
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
      reconcileScrollTarget(with: presentation.scrollNodeIDs)
      requestLatestWindowIfNeeded(presentation)
    }
    .onChange(of: sessionID) { _, _ in
      scrollTargetID = nil
      requestLatestWindow()
    }
    .onChange(of: presentation.scrollNodeIDs) { _, ids in
      reconcileScrollTarget(with: ids)
    }
  }

  private func timelineSurface(for presentation: SessionTimelineSectionPresentation) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingLG) {
      if presentation.navigation.showsNavigation {
        SessionTimelineNavigationControls(
          navigation: presentation.navigation,
          canScrollOlder: presentation.canScrollOlder(from: scrollTargetID),
          canScrollNewer: presentation.canScrollNewer(from: scrollTargetID),
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
        SessionTimelineTableView(
          rows: presentation.rows,
          scrollTargetID: scrollTargetID,
          actionHandler: actionHandler,
          viewportStatsChanged: { viewportStats in
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

  private func requestLatestWindowIfNeeded(_ presentation: SessionTimelineSectionPresentation) {
    guard !presentation.hasLatestWindow else {
      return
    }
    requestLatestWindow()
  }

  private func requestLatestWindow() {
    Task {
      await loadWindow(.latest(limit: SessionTimelineWindowNavigation.defaultLimit))
    }
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
    guard !isTimelineLoading,
      let request = presentation.navigation.request(for: action)
    else {
      return
    }
    Task {
      await loadWindow(request)
    }
  }

  private func performNavigationAction(
    _ action: SessionTimelineWindowAction,
    presentation: SessionTimelineSectionPresentation
  ) {
    Task {
      switch action {
      case .older:
        await loadOlderWindowBeforeSteppingIfNeeded(presentation)
        await scroll(
          to: presentation.nextOlderNodeID(from: scrollTargetID) ?? presentation.scrollNodeIDs.last
        )
      case .latest:
        if !presentation.hasLatestWindow || presentation.navigation.hasNewer {
          await loadWindow(.latest(limit: SessionTimelineWindowNavigation.defaultLimit))
        }
        await scroll(to: presentation.scrollNodeIDs.first)
      case .newer:
        if presentation.nextNewerNodeID(from: scrollTargetID) == nil {
          await loadWindowIfAvailable(for: .newer, presentation: presentation)
        }
        await scroll(
          to: presentation.nextNewerNodeID(from: scrollTargetID) ?? presentation.scrollNodeIDs.first
        )
      }
    }
  }

  private func loadOlderWindowBeforeSteppingIfNeeded(
    _ presentation: SessionTimelineSectionPresentation
  ) async {
    guard presentation.shouldLoadOlderBeforeStepping(from: scrollTargetID) else {
      return
    }
    await loadWindowIfAvailable(for: .older, presentation: presentation)
  }

  private func loadWindowIfAvailable(
    for action: SessionTimelineWindowAction,
    presentation: SessionTimelineSectionPresentation
  ) async {
    guard let request = presentation.navigation.request(for: action) else {
      return
    }
    await loadWindow(request)
  }

  private func scroll(to targetID: String?) async {
    guard let targetID else {
      return
    }
    await MainActor.run {
      withAnimation(reduceMotion ? nil : .snappy(duration: 0.22, extraBounce: 0)) {
        scrollTargetID = targetID
      }
    }
  }

  private func reconcileScrollTarget(with ids: [String]) {
    guard !ids.isEmpty else {
      scrollTargetID = nil
      return
    }
    guard let scrollTargetID else {
      self.scrollTargetID = ids.first
      return
    }
    if !ids.contains(scrollTargetID) {
      self.scrollTargetID = ids.first
    }
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
