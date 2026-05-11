import HarnessMonitorKit
import SwiftUI

enum SessionTimelineWindowAction: Equatable, Sendable {
  case older
  case latest
  case newer
}

struct SessionTimelineWindowNavigation: Equatable, Sendable {
  static let defaultLimit = HarnessMonitorStore.initialSelectedTimelineWindowLimit

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

  var showsNavigation: Bool {
    totalCount > 0 || isLoading
  }

  func request(
    for action: SessionTimelineWindowAction,
    limit requestedLimit: Int? = nil
  ) -> TimelineWindowRequest? {
    let requestLimit = requestedLimit ?? limit
    switch action {
    case .older:
      guard hasOlder, let oldestCursor else { return nil }
      return TimelineWindowRequest(scope: .summary, limit: requestLimit, before: oldestCursor)
    case .latest:
      return .latest(limit: requestLimit)
    case .newer:
      guard hasNewer, let newestCursor else { return nil }
      return TimelineWindowRequest(scope: .summary, limit: requestLimit, after: newestCursor)
    }
  }
}

struct SessionTimelineCountSummary: View {
  let navigation: SessionTimelineWindowNavigation
  let filterSummary: SessionTimelineFilterSummary
  let filterMatchCount: Int?

  var body: some View {
    let text = Self.statusText(
      navigation: navigation,
      filterSummary: filterSummary,
      filterMatchCount: filterMatchCount
    )
    if !text.isEmpty {
      Text(text)
        .scaledFont(.caption2)
        .monospacedDigit()
        .lineLimit(1)
        .truncationMode(.tail)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .accessibilityIdentifier(HarnessMonitorAccessibility.sessionTimelineVisibleStatus)
    }
  }

  static func statusText(
    navigation: SessionTimelineWindowNavigation,
    filterSummary: SessionTimelineFilterSummary,
    filterMatchCount: Int?
  ) -> String {
    if filterSummary.isFiltered, let filterMatchCount {
      let filterLabel =
        filterSummary.activeFilterCount == 1
        ? "1 filter"
        : "\(filterSummary.activeFilterCount) filters"
      let baseText =
        filterMatchCount == 1
        ? "1 match"
        : "\(filterMatchCount) matches"
      return "\(baseText) • \(filterLabel)"
    }
    guard navigation.totalCount > 0 else { return "" }
    let total = navigation.totalCount
    let loaded = navigation.loadedCount
    let start = navigation.windowStart
    let end = min(start + loaded, total)
    if start == 0 && end == total {
      return total == 1 ? "1 event" : "\(total) events"
    }
    return "Showing \(start + 1)-\(end) of \(total)"
  }
}
