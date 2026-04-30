import HarnessMonitorKit
import SwiftUI

struct SessionTimelineSectionPresentation {
  private static let maximumVisibleRows = 6
  private static let rowHeightEstimate: CGFloat = 74
  private static let minimumViewportHeight: CGFloat = 260
  private static let maximumViewportHeight: CGFloat = 470

  let navigation: SessionTimelineWindowNavigation
  let rows: [SessionTimelineRow]
  let placeholderCount: Int
  let shouldAnimatePlaceholders: Bool
  let viewportHeight: CGFloat
  let scrollNodeIDs: [String]

  init(
    sessionID: String,
    timeline: [TimelineEntry],
    timelineWindow: TimelineWindowResponse?,
    decisions: [Decision],
    isTimelineLoading: Bool,
    reduceMotion: Bool,
    dateTimeConfiguration: HarnessMonitorDateTimeConfiguration
  ) {
    let navigation = SessionTimelineWindowNavigation(
      timeline: timeline,
      timelineWindow: timelineWindow,
      isLoading: isTimelineLoading
    )
    let nodes = SessionTimelineNodeBuilder(
      sessionID: sessionID,
      entries: timeline,
      decisions: decisions
    )
    .build()
    let placeholderCount = isTimelineLoading && nodes.isEmpty ? navigation.limit : 0
    let loadedCount = nodes.count + placeholderCount
    let visibleRows = min(max(loadedCount, 1), Self.maximumVisibleRows)

    self.navigation = navigation
    rows = SessionTimelineRow.rows(for: nodes, configuration: dateTimeConfiguration)
    self.placeholderCount = placeholderCount
    shouldAnimatePlaceholders = SessionTimelinePlaceholderShimmer.shouldAnimate(
      reduceMotion: reduceMotion,
      placeholderCount: placeholderCount
    )
    viewportHeight = min(
      max(
        (CGFloat(visibleRows) * Self.rowHeightEstimate) + HarnessMonitorTheme.spacingLG,
        Self.minimumViewportHeight),
      Self.maximumViewportHeight
    )
    scrollNodeIDs = nodes.map(\.id)
  }

  var showsEmptyState: Bool {
    !navigation.isLoading && navigation.totalCount == 0 && rows.isEmpty
  }

  func canScrollOlder(from targetID: String?) -> Bool {
    nextOlderNodeID(from: targetID) != nil || navigation.hasOlder
  }

  func canScrollNewer(from targetID: String?) -> Bool {
    nextNewerNodeID(from: targetID) != nil || navigation.hasNewer
  }

  func nextOlderNodeID(from targetID: String?) -> String? {
    let currentIndex = currentNodeIndex(for: targetID) ?? 0
    let nextIndex = currentIndex + 1
    guard scrollNodeIDs.indices.contains(nextIndex) else {
      return nil
    }
    return scrollNodeIDs[nextIndex]
  }

  func nextNewerNodeID(from targetID: String?) -> String? {
    guard let currentIndex = currentNodeIndex(for: targetID) else {
      return nil
    }
    let previousIndex = currentIndex - 1
    guard scrollNodeIDs.indices.contains(previousIndex) else {
      return nil
    }
    return scrollNodeIDs[previousIndex]
  }

  func shouldLoadOlderBeforeStepping(from targetID: String?) -> Bool {
    navigation.hasOlder
      && (nextOlderNodeID(from: targetID) == nil || rows.count <= Self.maximumVisibleRows)
  }

  var hasLatestWindow: Bool {
    navigation.windowStart == 0
      && !navigation.hasNewer
      && (!rows.isEmpty || navigation.totalCount == 0)
  }

  private func currentNodeIndex(for targetID: String?) -> Int? {
    guard let targetID else {
      return nil
    }
    return scrollNodeIDs.firstIndex(of: targetID)
  }
}
