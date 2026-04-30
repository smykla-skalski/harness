import HarnessMonitorKit
import SwiftUI

enum SessionTimelinePlaceholderShimmer {
  static let cycleDuration: TimeInterval = 1.15
  private static let leadingPhase: CGFloat = -0.6
  private static let trailingPhase: CGFloat = 1.8

  static func shouldAnimate(reduceMotion: Bool, placeholderCount: Int) -> Bool {
    !reduceMotion && placeholderCount > 0
  }

  static func phase(at date: Date) -> CGFloat {
    let cycleProgress =
      date.timeIntervalSinceReferenceDate
      .truncatingRemainder(dividingBy: cycleDuration)
      / cycleDuration
    return leadingPhase + ((trailingPhase - leadingPhase) * cycleProgress)
  }

  static var restingPhase: CGFloat {
    0
  }
}

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

  private var contentIdentity: SessionTimelineContentIdentity {
    SessionTimelineContentIdentity(sessionID: sessionID)
  }

  var body: some View {
    let presentation = makePresentation()
    ViewBodySignposter.measure("SessionCockpitTimelineSection") {
      content(for: presentation)
    }
  }

  @MainActor
  private func makePresentation() -> SessionTimelineSectionPresentation {
    SessionTimelineSectionPresentation(
      sessionID: sessionID,
      timeline: timeline,
      timelineWindow: timelineWindow,
      decisions: decisions,
      isTimelineLoading: isTimelineLoading,
      reduceMotion: reduceMotion,
      dateTimeConfiguration: dateTimeConfiguration
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
    ScrollView {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        SessionTimelineCards(
          rows: presentation.rows,
          placeholderCount: presentation.placeholderCount,
          shimmerPhase: SessionTimelinePlaceholderShimmer.restingPhase,
          showsShimmer: presentation.shouldAnimatePlaceholders,
          actionHandler: actionHandler
        )
      }
      .id(contentIdentity)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(height: presentation.viewportHeight)
    .scrollIndicators(.visible)
    .scrollBounceBehavior(.always, axes: .vertical)
    .scrollClipDisabled(false)
    .scrollPosition(id: $scrollTargetID, anchor: .top)
    .onScrollGeometryChange(
      for: SessionTimelineScrollBoundaryState.self,
      of: SessionTimelineScrollBoundaryState.init(geometry:)
    ) { oldValue, newValue in
      handleScrollBoundaryChange(
        from: oldValue,
        to: newValue,
        presentation: presentation
      )
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

struct SessionTimelineContentIdentity: Hashable, Sendable {
  let sessionID: String
}

#Preview("Timeline Cursor") {
  SessionCockpitTimelineSection(
    sessionID: PreviewFixtures.summary.sessionId,
    timeline: Array(PreviewFixtures.pagedTimeline.prefix(6)),
    timelineWindow: TimelineWindowResponse(
      revision: 1,
      totalCount: PreviewFixtures.pagedTimeline.count,
      windowStart: 0,
      windowEnd: 6,
      hasOlder: true,
      hasNewer: false,
      oldestCursor: TimelineCursor(
        recordedAt: PreviewFixtures.pagedTimeline[5].recordedAt,
        entryId: PreviewFixtures.pagedTimeline[5].entryId
      ),
      newestCursor: TimelineCursor(
        recordedAt: PreviewFixtures.pagedTimeline[0].recordedAt,
        entryId: PreviewFixtures.pagedTimeline[0].entryId
      ),
      entries: nil,
      unchanged: false
    ),
    decisions: [],
    isTimelineLoading: false,
    actionHandler: NullDecisionActionHandler(),
    loadWindow: { _ in }
  )
  .padding()
  .frame(width: 960)
}

#Preview("Timeline") {
  SessionCockpitTimelineSection(
    sessionID: PreviewFixtures.summary.sessionId,
    timeline: PreviewFixtures.timeline,
    timelineWindow: .fallbackMetadata(for: PreviewFixtures.timeline),
    decisions: [],
    isTimelineLoading: false,
    actionHandler: NullDecisionActionHandler(),
    loadWindow: { _ in }
  )
  .padding()
  .frame(width: 960)
}
