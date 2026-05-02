import HarnessMonitorKit
import SwiftUI

enum SessionTimelineWindowAction: Equatable, Sendable {
  case older
  case latest
  case newer
}

struct SessionTimelinePendingNavigation: Equatable, Sendable {
  let action: SessionTimelineWindowAction
  let request: TimelineWindowRequest
  let sessionID: String
  let generation: Int

  func isSatisfied(
    sessionID currentSessionID: String,
    navigation: SessionTimelineWindowNavigation
  ) -> Bool {
    guard sessionID == currentSessionID else {
      return false
    }
    switch action {
    case .older, .newer:
      return navigation.request(for: action) != request
    case .latest:
      return !navigation.hasNewer
    }
  }
}

struct SessionTimelineWindowNavigation: Equatable, Sendable {
  static let defaultLimit = 24

  let limit: Int
  let totalCount: Int
  let loadedCount: Int
  let windowStart: Int
  let windowEnd: Int
  let hasOlder: Bool
  let hasNewer: Bool
  let oldestCursor: TimelineCursor?
  let newestCursor: TimelineCursor?
  let isLoading: Bool

  init(
    timeline: [TimelineEntry],
    timelineWindow: TimelineWindowResponse?,
    isLoading: Bool,
    limit: Int = Self.defaultLimit
  ) {
    self.limit = limit
    loadedCount = timeline.count
    totalCount = max(timeline.count, timelineWindow?.totalCount ?? 0)
    windowStart = timelineWindow?.windowStart ?? 0
    windowEnd = timelineWindow?.windowEnd ?? timeline.count
    hasOlder = timelineWindow?.hasOlder ?? false
    hasNewer = timelineWindow?.hasNewer ?? false
    oldestCursor =
      timelineWindow?.oldestCursor
      ?? timeline.last.map {
        TimelineCursor(recordedAt: $0.recordedAt, entryId: $0.entryId)
      }
    newestCursor =
      timelineWindow?.newestCursor
      ?? timeline.first.map {
        TimelineCursor(recordedAt: $0.recordedAt, entryId: $0.entryId)
      }
    self.isLoading = isLoading
  }

  var statusText: String {
    if totalCount == 0 {
      return isLoading ? "Loading latest activity" : "No timeline events"
    }
    if windowStart == 0 && !hasNewer {
      return "Latest \(visibleWindowEnd) of \(totalCount)"
    }
    return "Showing \(visibleWindowStart + 1)-\(visibleWindowEnd) of \(totalCount)"
  }

  private var visibleWindowStart: Int {
    max(0, min(windowStart, totalCount))
  }

  private var visibleWindowEnd: Int {
    max(visibleWindowStart, min(windowEnd, totalCount))
  }

  var showsNavigation: Bool {
    totalCount > 0 || isLoading
  }

  func request(for action: SessionTimelineWindowAction) -> TimelineWindowRequest? {
    switch action {
    case .older:
      guard hasOlder, let oldestCursor else {
        return nil
      }
      return TimelineWindowRequest(scope: .summary, limit: limit, before: oldestCursor)
    case .latest:
      return .latest(limit: limit)
    case .newer:
      guard hasNewer, let newestCursor else {
        return nil
      }
      return TimelineWindowRequest(scope: .summary, limit: limit, after: newestCursor)
    }
  }
}

struct SessionTimelineNavigationControls: View {
  let navigation: SessionTimelineWindowNavigation
  let presentation: SessionTimelineSectionPresentation
  let scrollCommandTargetID: String?
  let viewport: SessionTimelineViewportModel
  let performAction: (SessionTimelineWindowAction) -> Void

  var body: some View {
    let anchorID = viewport.visibleAnchorID ?? scrollCommandTargetID
    let canOlder = presentation.canScrollOlder(from: anchorID)
    let canNewer = presentation.canScrollNewer(from: anchorID)
    let visibilityStats = viewport.visibilityStats
    return ViewThatFits(in: .horizontal) {
      horizontalControls(
        canOlder: canOlder,
        canNewer: canNewer,
        visibilityStats: visibilityStats
      )
      verticalControls(
        canOlder: canOlder,
        canNewer: canNewer,
        visibilityStats: visibilityStats
      )
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Timeline navigation")
    .accessibilityIdentifier(HarnessMonitorAccessibility.sessionTimelineNavigation)
  }

  private func horizontalControls(
    canOlder: Bool,
    canNewer: Bool,
    visibilityStats: SessionTimelineVisibilityStats
  ) -> some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.itemSpacing) {
      statusLabel
      visibleStatusLabel(visibilityStats)
      Spacer(minLength: 0)
      buttons(canOlder: canOlder, canNewer: canNewer)
    }
  }

  private func verticalControls(
    canOlder: Bool,
    canNewer: Bool,
    visibilityStats: SessionTimelineVisibilityStats
  ) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      statusLabel
      visibleStatusLabel(visibilityStats)
      buttons(canOlder: canOlder, canNewer: canNewer)
    }
  }

  private var statusLabel: some View {
    Text(navigation.statusText)
      .scaledFont(.caption.monospaced())
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      .accessibilityIdentifier(HarnessMonitorAccessibility.sessionTimelineNavigationStatus)
  }

  private func visibleStatusLabel(
    _ visibilityStats: SessionTimelineVisibilityStats
  ) -> some View {
    Text(visibilityStats.statusText)
      .scaledFont(.caption2.monospaced())
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      .accessibilityIdentifier(HarnessMonitorAccessibility.sessionTimelineVisibleStatus)
  }

  private func buttons(canOlder: Bool, canNewer: Bool) -> some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
      navigationButton(
        title: "Older",
        systemImage: "chevron.down",
        action: .older,
        isEnabled: canOlder,
        identifier: HarnessMonitorAccessibility.sessionTimelineOlderButton
      )
      navigationButton(
        title: "Latest",
        systemImage: "clock.arrow.circlepath",
        action: .latest,
        isEnabled: true,
        identifier: HarnessMonitorAccessibility.sessionTimelineLatestButton
      )
      navigationButton(
        title: "Newer",
        systemImage: "chevron.up",
        action: .newer,
        isEnabled: canNewer,
        identifier: HarnessMonitorAccessibility.sessionTimelineNewerButton
      )
    }
  }

  private func navigationButton(
    title: String,
    systemImage: String,
    action: SessionTimelineWindowAction,
    isEnabled: Bool,
    identifier: String
  ) -> some View {
    Button {
      performAction(action)
    } label: {
      Label(title, systemImage: systemImage)
    }
    .harnessActionButtonStyle(variant: .bordered, tint: nil)
    .controlSize(HarnessMonitorControlMetrics.compactControlSize)
    .disabled(!isEnabled)
    .accessibilityIdentifier(identifier)
  }
}
