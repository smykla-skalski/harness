import HarnessMonitorKit
import SwiftUI

struct SessionTimelineSectionPresentation {
  let navigation: SessionTimelineWindowNavigation
  let filterSnapshot: SessionTimelineFilterSnapshot
  let rows: [SessionTimelineRow]

  private init(
    navigation: SessionTimelineWindowNavigation,
    filterSnapshot: SessionTimelineFilterSnapshot,
    rows: [SessionTimelineRow]
  ) {
    self.navigation = navigation
    self.filterSnapshot = filterSnapshot
    self.rows = rows
  }

  static let empty = Self(
    navigation: SessionTimelineWindowNavigation(
      timeline: [],
      timelineWindow: nil,
      isLoading: false
    ),
    filterSnapshot: .empty,
    rows: []
  )

  @MainActor
  init(
    sessionID: String,
    timeline: [TimelineEntry],
    timelineWindow: TimelineWindowResponse?,
    decisions: [Decision],
    signals: [SessionSignalRecord],
    filters: SessionTimelineFilterState,
    isTimelineLoading: Bool,
    dateTimeConfiguration: HarnessMonitorDateTimeConfiguration,
    now: Date = Date()
  ) {
    navigation = SessionTimelineWindowNavigation(
      timeline: timeline,
      timelineWindow: timelineWindow,
      isLoading: isTimelineLoading
    )
    var signalsByID = [String: SessionSignalRecord]()
    for record in signals { signalsByID[record.signal.signalId] = record }
    let context = TimelineFeatureContext(now: now, signalsByID: signalsByID)
    let sourceNodes = SessionTimelineNodeBuilder(
      sessionID: sessionID,
      entries: timeline,
      decisions: decisions,
      context: context
    )
    .build()
    filterSnapshot = SessionTimelineFilterSnapshot(
      nodes: sourceNodes,
      filters: filters,
      configuration: dateTimeConfiguration
    )
    rows = filterSnapshot.rows
  }

  var showsEmptyState: Bool {
    !navigation.isLoading && navigation.totalCount == 0 && rows.isEmpty
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

  var hasLatestWindow: Bool {
    navigation.windowStart == 0
      && !navigation.hasNewer
      && (!rows.isEmpty || navigation.totalCount == 0)
  }
}
