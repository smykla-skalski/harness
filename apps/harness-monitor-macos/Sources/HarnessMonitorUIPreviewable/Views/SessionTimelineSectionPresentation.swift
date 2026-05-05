import HarnessMonitorKit
import SwiftUI

struct SessionTimelineSectionPresentation {
  private static let maximumVisibleRows = 6
  static let rowHeightEstimate: CGFloat = 74
  private static let minimumViewportHeight: CGFloat = 260
  private static let maximumViewportHeight: CGFloat = 470

  let navigation: SessionTimelineWindowNavigation
  let filterSnapshot: SessionTimelineFilterSnapshot
  let rows: [SessionTimelineRow]
  let placeholderCount: Int
  let shouldAnimatePlaceholders: Bool
  let viewportHeight: CGFloat
  let scrollNodeIDs: [String]
  private let textSizeIndex: Int

  private init(
    navigation: SessionTimelineWindowNavigation,
    filterSnapshot: SessionTimelineFilterSnapshot,
    rows: [SessionTimelineRow],
    placeholderCount: Int,
    shouldAnimatePlaceholders: Bool,
    viewportHeight: CGFloat,
    scrollNodeIDs: [String],
    textSizeIndex: Int
  ) {
    self.navigation = navigation
    self.filterSnapshot = filterSnapshot
    self.rows = rows
    self.placeholderCount = placeholderCount
    self.shouldAnimatePlaceholders = shouldAnimatePlaceholders
    self.viewportHeight = viewportHeight
    self.scrollNodeIDs = scrollNodeIDs
    self.textSizeIndex = textSizeIndex
  }

  static var empty: Self {
    Self(
      navigation: SessionTimelineWindowNavigation(
        timeline: [],
        timelineWindow: nil,
        isLoading: false
      ),
      filterSnapshot: .empty,
      rows: [],
      placeholderCount: 0,
      shouldAnimatePlaceholders: false,
      viewportHeight: minimumViewportHeight,
      scrollNodeIDs: [],
      textSizeIndex: HarnessMonitorTextSize.defaultIndex
    )
  }

  @MainActor
  init(
    sessionID: String,
    timeline: [TimelineEntry],
    timelineWindow: TimelineWindowResponse?,
    decisions: [Decision],
    filters: SessionTimelineFilterState,
    isTimelineLoading: Bool,
    reduceMotion: Bool,
    textSizeIndex: Int,
    dateTimeConfiguration: HarnessMonitorDateTimeConfiguration
  ) {
    let navigation = SessionTimelineWindowNavigation(
      timeline: timeline,
      timelineWindow: timelineWindow,
      isLoading: isTimelineLoading
    )
    let sourceNodes = SessionTimelineNodeBuilder(
      sessionID: sessionID,
      entries: timeline,
      decisions: decisions
    )
    .build()
    let filterSnapshot = SessionTimelineFilterSnapshot(
      nodes: sourceNodes,
      filters: filters,
      configuration: dateTimeConfiguration
    )
    let placeholderCount = isTimelineLoading && sourceNodes.isEmpty ? navigation.limit : 0
    let loadedCount = filterSnapshot.nodes.count + placeholderCount
    let visibleRows = min(max(loadedCount, 1), Self.maximumVisibleRows)

    let shouldAnimatePlaceholders = SessionTimelinePlaceholderShimmer.shouldAnimate(
      reduceMotion: reduceMotion,
      placeholderCount: placeholderCount
    )
    let viewportHeight = min(
      max(
        (CGFloat(visibleRows) * Self.rowHeightEstimate) + HarnessMonitorTheme.spacingLG,
        Self.minimumViewportHeight),
      Self.maximumViewportHeight
    )
    self.navigation = navigation
    self.filterSnapshot = filterSnapshot
    rows = filterSnapshot.rows
    self.placeholderCount = placeholderCount
    self.shouldAnimatePlaceholders = shouldAnimatePlaceholders
    self.viewportHeight = viewportHeight
    self.scrollNodeIDs = filterSnapshot.nodes.map(\.id)
    self.textSizeIndex = textSizeIndex
  }

  var showsEmptyState: Bool {
    !navigation.isLoading && navigation.totalCount == 0 && rows.isEmpty
  }

  var rowIDs: [String] {
    rows.map(\.id)
  }

  var showsFilteredEmptyState: Bool {
    filterSnapshot.summary.isFiltered
      && filterSnapshot.sourceNodeCount > 0
      && rows.isEmpty
      && !navigation.isLoading
  }

  var filterMatchCountForVisibilityStats: Int? {
    filterSnapshot.summary.isFiltered ? filterSnapshot.filteredNodeCount : nil
  }

  var fallbackVisibleRowCount: Int {
    min(max(rows.count + placeholderCount, 0), Self.maximumVisibleRows)
  }

  var scrollViewportHeight: CGFloat {
    guard navigation.showsNavigation else {
      return viewportHeight
    }
    let reservedFooterHeight =
      Self.navigationFooterHeight(for: textSizeIndex) + HarnessMonitorTheme.spacingLG
    let minimumViewportHeight = Self.minimumScrollViewportHeight(for: textSizeIndex)
    let availableViewportHeight = viewportHeight - reservedFooterHeight
    return max(minimumViewportHeight, availableViewportHeight)
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

  private static func navigationFooterHeight(for textSizeIndex: Int) -> CGFloat {
    switch HarnessMonitorTextSize.controlSize(at: textSizeIndex) {
    case .small:
      36
    case .regular:
      44
    case .large:
      72
    case .extraLarge:
      84
    case .mini:
      36
    @unknown default:
      44
    }
  }

  private static func minimumScrollViewportHeight(for textSizeIndex: Int) -> CGFloat {
    switch HarnessMonitorTextSize.controlSize(at: textSizeIndex) {
    case .small:
      180
    case .regular:
      192
    case .large:
      208
    case .extraLarge:
      220
    case .mini:
      180
    @unknown default:
      192
    }
  }
}
