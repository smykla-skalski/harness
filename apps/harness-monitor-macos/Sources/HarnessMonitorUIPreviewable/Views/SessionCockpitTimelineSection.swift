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
  let scrollToTimelineTarget: (SessionTimelineScrollTarget) -> Void

  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  private var navigation: SessionTimelineWindowNavigation {
    SessionTimelineWindowNavigation(
      timeline: timeline,
      timelineWindow: timelineWindow,
      isLoading: isTimelineLoading
    )
  }

  private var nodes: [SessionTimelineNode] {
    SessionTimelineNodeBuilder(
      sessionID: sessionID,
      entries: timeline,
      decisions: decisions
    )
    .build()
  }

  private var placeholderCount: Int {
    isTimelineLoading && nodes.isEmpty ? navigation.limit : 0
  }

  private var shouldAnimatePlaceholders: Bool {
    SessionTimelinePlaceholderShimmer.shouldAnimate(
      reduceMotion: reduceMotion,
      placeholderCount: placeholderCount
    )
  }

  private var showsEmptyState: Bool {
    !isTimelineLoading && navigation.totalCount == 0 && nodes.isEmpty
  }

  private var contentIdentity: SessionTimelineContentIdentity {
    SessionTimelineContentIdentity(sessionID: sessionID)
  }

  var body: some View {
    ViewBodySignposter.measure("SessionCockpitTimelineSection") {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
        Text("Timeline")
          .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
          .accessibilityAddTraits(.isHeader)

        if showsEmptyState {
          SessionCockpitEmptyStateRow(section: .timeline)
        } else {
          timelineSurface
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .onAppear {
        requestLatestWindowIfNeeded()
      }
      .onChange(of: sessionID) { _, _ in
        requestLatestWindow()
      }
    }
  }

  private var timelineSurface: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingLG) {
      if navigation.showsNavigation {
        SessionTimelineNavigationControls(
          navigation: navigation,
          performAction: performNavigationAction(_:)
        )
      }

      edgeAnchor(.top)
      SessionTimelineCards(
        nodes: nodes,
        placeholderCount: placeholderCount,
        shimmerPhase: SessionTimelinePlaceholderShimmer.restingPhase,
        showsShimmer: shouldAnimatePlaceholders,
        dateTimeConfiguration: dateTimeConfiguration,
        actionHandler: actionHandler
      )
      .id(contentIdentity)
      edgeAnchor(.bottom)
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

  private func requestLatestWindowIfNeeded() {
    guard !hasLatestWindow else {
      return
    }
    requestLatestWindow()
  }

  private func requestLatestWindow() {
    Task {
      await loadWindow(.latest(limit: SessionTimelineWindowNavigation.defaultLimit))
    }
  }

  private func requestOlderWindowIfNeeded() {
    requestWindowIfNeeded(for: .older)
  }

  private func requestNewerWindowIfNeeded() {
    requestWindowIfNeeded(for: .newer)
  }

  private func requestWindowIfNeeded(for action: SessionTimelineWindowAction) {
    guard !isTimelineLoading,
      let request = navigation.request(for: action)
    else {
      return
    }
    Task {
      await loadWindow(request)
    }
  }

  private func performNavigationAction(_ action: SessionTimelineWindowAction) {
    Task {
      switch action {
      case .older:
        await loadWindowIfAvailable(for: .older)
        await scroll(afterLoadTo: .bottom)
      case .latest:
        if !hasLatestWindow || navigation.hasNewer {
          await loadWindow(.latest(limit: SessionTimelineWindowNavigation.defaultLimit))
        }
        await scroll(afterLoadTo: .top)
      case .newer:
        await loadWindowIfAvailable(for: .newer)
        await scroll(afterLoadTo: .top)
      }
    }
  }

  private func loadWindowIfAvailable(for action: SessionTimelineWindowAction) async {
    guard let request = navigation.request(for: action) else {
      return
    }
    await loadWindow(request)
  }

  private func scroll(afterLoadTo target: SessionTimelineScrollTarget) async {
    await Task.yield()
    await MainActor.run {
      scrollToTimelineTarget(target)
    }
  }

  private func edgeAnchor(_ target: SessionTimelineScrollTarget) -> some View {
    Color.clear
      .frame(height: 1)
      .id(target.id)
      .accessibilityHidden(true)
      .onAppear {
        switch target {
        case .top:
          requestNewerWindowIfNeeded()
        case .bottom:
          requestOlderWindowIfNeeded()
        }
      }
  }

  private var hasLatestWindow: Bool {
    guard let timelineWindow else {
      return false
    }
    return timelineWindow.windowStart == 0
      && timelineWindow.hasNewer == false
      && timelineWindow.pageSize == SessionTimelineWindowNavigation.defaultLimit
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
    loadWindow: { _ in },
    scrollToTimelineTarget: { _ in }
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
    loadWindow: { _ in },
    scrollToTimelineTarget: { _ in }
  )
  .padding()
  .frame(width: 960)
}
