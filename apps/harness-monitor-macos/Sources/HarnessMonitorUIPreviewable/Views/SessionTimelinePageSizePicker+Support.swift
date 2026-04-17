import HarnessMonitorKit
import SwiftUI

enum SessionTimelinePageSize: Int, CaseIterable, Identifiable {
  case ten = 10
  case fifteen = 15
  case thirty = 30
  case fifty = 50

  static let defaultSize: Self = .ten

  var id: Int { rawValue }
  var label: String { "\(rawValue)" }
}

enum SessionTimelinePagination {
  private static let maxVisiblePageButtons = 5

  static func clampedPage(_ page: Int, itemCount: Int, pageSize: Int) -> Int {
    let resolvedPageCount = pageCount(for: itemCount, pageSize: pageSize)
    guard resolvedPageCount > 0 else {
      return 0
    }

    return min(max(page, 0), resolvedPageCount - 1)
  }

  static func adjustedPage(
    currentPage: Int,
    itemCount: Int,
    pageSize: Int
  ) -> Int? {
    let clampedCurrentPage = clampedPage(
      currentPage,
      itemCount: itemCount,
      pageSize: pageSize
    )
    guard clampedCurrentPage != currentPage else {
      return nil
    }

    return clampedCurrentPage
  }

  static func adjustedPageAfterTimelineCountChange(
    currentPage: Int,
    oldItemCount: Int,
    newItemCount: Int,
    pageSize: Int
  ) -> Int? {
    guard newItemCount < oldItemCount else {
      return nil
    }

    return adjustedPage(
      currentPage: currentPage,
      itemCount: newItemCount,
      pageSize: pageSize
    )
  }

  static func currentEntries(
    in timeline: [TimelineEntry],
    currentPage: Int,
    pageSize: Int
  ) -> [TimelineEntry] {
    let clampedCurrentPage = clampedPage(
      currentPage,
      itemCount: timeline.count,
      pageSize: pageSize
    )
    let startIndex = clampedCurrentPage * pageSize
    let endIndex = min(startIndex + pageSize, timeline.count)
    return Array(timeline[startIndex..<endIndex])
  }

  static func pageCount(for itemCount: Int, pageSize: Int) -> Int {
    max(1, Int(ceil(Double(itemCount) / Double(pageSize))))
  }

  static func rebasedPage(
    _ currentPage: Int,
    itemCount: Int,
    oldPageSize: Int,
    newPageSize: Int
  ) -> Int {
    guard itemCount > 0 else {
      return 0
    }

    let firstVisibleIndex =
      clampedPage(
        currentPage,
        itemCount: itemCount,
        pageSize: oldPageSize
      ) * oldPageSize
    let rebasedPage = firstVisibleIndex / newPageSize
    return clampedPage(rebasedPage, itemCount: itemCount, pageSize: newPageSize)
  }

  static func visiblePages(
    currentPage: Int,
    pageCount: Int
  ) -> [Int] {
    guard pageCount > 0 else {
      return []
    }

    let buttonCount = min(pageCount, maxVisiblePageButtons)
    let halfWindow = buttonCount / 2
    var startPage = max(0, currentPage - halfWindow)
    var endPage = startPage + buttonCount - 1

    if endPage >= pageCount {
      endPage = pageCount - 1
      startPage = max(0, endPage - buttonCount + 1)
    }

    return Array(startPage...endPage)
  }
}

struct SessionTimelinePageDisplay: Equatable, Sendable {
  let page: Int
  let entries: [TimelineEntry]
  let placeholderCount: Int
  let rangeText: String
  let pageStatusText: String
  let isWaitingForRequestedPage: Bool
}

struct SessionTimelineRetainedPage: Equatable, Sendable {
  let sessionID: String
  let pageSize: Int
  let display: SessionTimelinePageDisplay

  func matches(sessionID: String, pageSize: Int) -> Bool {
    self.sessionID == sessionID && self.pageSize == pageSize
  }
}

struct SessionTimelinePresentation {
  let timeline: [TimelineEntry]
  let timelineWindow: TimelineWindowResponse?
  let currentPage: Int
  let pageSize: Int
  let isLoading: Bool

  private var loadedCount: Int { timeline.count }

  var totalCount: Int {
    max(loadedCount, timelineWindow?.totalCount ?? 0)
  }

  var resolvedCurrentPage: Int {
    currentDisplay.page
  }

  var pageCount: Int {
    SessionTimelinePagination.pageCount(for: totalCount, pageSize: pageSize)
  }

  var rangeText: String {
    currentDisplay.rangeText
  }

  var pageStatusText: String {
    currentDisplay.pageStatusText
  }

  func interactivePage(forRequestedPage requestedPage: Int) -> Int {
    SessionTimelinePagination.clampedPage(
      requestedPage,
      itemCount: totalCount,
      pageSize: pageSize
    )
  }

  var showsPagination: Bool {
    pageCount > 1
  }

  /// True when metadata claims entries exist but none have landed in memory and
  /// no fetch is in flight. The view uses this to trigger a page-zero reload so
  /// stale "Showing 0-0 of N" cards self-heal instead of waiting for the user
  /// to change page size or reselect the session.
  var needsRefresh: Bool {
    !isLoading && totalCount > 0 && currentDisplay.entries.isEmpty
  }

  var entries: [TimelineEntry] {
    currentDisplay.entries
  }

  var placeholderCount: Int {
    currentDisplay.placeholderCount
  }

  func display(forRequestedPage requestedPage: Int) -> SessionTimelinePageDisplay {
    let resolvedPage = interactivePage(forRequestedPage: requestedPage)
    let visibleRange = visibleRange(for: resolvedPage)
    let entries = entries(in: visibleRange)
    return SessionTimelinePageDisplay(
      page: resolvedPage,
      entries: entries,
      placeholderCount: placeholderCount(for: visibleRange, entries: entries),
      rangeText: rangeText(for: visibleRange, entries: entries),
      pageStatusText: "Page \(resolvedPage + 1) of \(pageCount)",
      isWaitingForRequestedPage: isWaitingForRequestedPage(
        visibleRange: visibleRange,
        entries: entries
      )
    )
  }

  func visibleDisplay(
    forRequestedPage requestedPage: Int,
    sessionID: String,
    pageSize: Int,
    retainedPage: SessionTimelineRetainedPage?
  ) -> SessionTimelinePageDisplay {
    let display = display(forRequestedPage: requestedPage)
    guard display.isWaitingForRequestedPage,
      let retainedPage,
      retainedPage.matches(sessionID: sessionID, pageSize: pageSize)
    else {
      return display
    }
    return retainedPage.display
  }

  private var currentDisplay: SessionTimelinePageDisplay {
    display(forRequestedPage: currentPage)
  }

  private func visibleRange(for page: Int) -> Range<Int> {
    let lowerBound = page * pageSize
    let upperBound = min(totalCount, lowerBound + pageSize)
    return lowerBound..<upperBound
  }

  private func entries(in visibleRange: Range<Int>) -> [TimelineEntry] {
    guard loadedCount > visibleRange.lowerBound else {
      return []
    }

    let loadedUpperBound = min(visibleRange.upperBound, loadedCount)
    return Array(timeline[visibleRange.lowerBound..<loadedUpperBound])
  }

  private func placeholderCount(
    for visibleRange: Range<Int>,
    entries: [TimelineEntry]
  ) -> Int {
    guard isLoading else {
      return 0
    }

    if totalCount == 0 {
      return pageSize
    }

    return max(0, visibleRange.count - entries.count)
  }

  private func rangeText(
    for visibleRange: Range<Int>,
    entries: [TimelineEntry]
  ) -> String {
    if totalCount == 0 {
      return isLoading ? "Loading latest activity" : "Showing 0-0 of 0"
    }

    if !isLoading, entries.isEmpty {
      return "Showing 0-0 of \(totalCount)"
    }

    return "Showing \(visibleRange.lowerBound + 1)-\(visibleRange.upperBound) of \(totalCount)"
  }

  private func isWaitingForRequestedPage(
    visibleRange: Range<Int>,
    entries: [TimelineEntry]
  ) -> Bool {
    totalCount > 0
      && loadedCount > 0
      && entries.isEmpty
      && visibleRange.lowerBound >= loadedCount
  }
}

struct SessionTimelineContentIdentity: Hashable, Sendable {
  let sessionID: String
}

#Preview("Timeline Summary - Wide") {
  @Previewable @State var pageSize = SessionTimelinePageSize.ten

  SessionTimelinePreviewSurface {
    SessionTimelinePageSummary(
      rangeText: "Showing 21-30 of 87",
      pageSize: $pageSize
    )
  }
  .frame(width: 620)
}

#Preview("Timeline Summary - Compact") {
  @Previewable @State var pageSize = SessionTimelinePageSize.fifteen

  SessionTimelinePreviewSurface {
    SessionTimelinePageSummary(
      rangeText: "Showing 31-45 of 87",
      pageSize: $pageSize
    )
  }
  .frame(width: 240)
}

#Preview("Timeline Pagination Footer") {
  SessionTimelinePreviewSurface {
    SessionTimelinePaginationFooter(
      currentPage: 5,
      pageCount: 12,
      pageStatusText: "Page 6 of 12",
      visiblePages: SessionTimelinePagination.visiblePages(
        currentPage: 5,
        pageCount: 12
      ),
      goToPreviousPage: {},
      goToNextPage: {},
      goToPage: { _ in }
    )
  }
  .frame(width: 820)
}

private struct SessionTimelinePreviewSurface<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    content
      .padding(HarnessMonitorTheme.spacingLG)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background {
        RoundedRectangle(
          cornerRadius: HarnessMonitorTheme.cornerRadiusLG,
          style: .continuous
        )
        .fill(.primary.opacity(0.035))
      }
      .padding()
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
