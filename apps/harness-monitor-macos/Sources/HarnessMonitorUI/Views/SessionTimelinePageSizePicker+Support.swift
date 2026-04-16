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
    SessionTimelinePagination.clampedPage(
      currentPage,
      itemCount: totalCount,
      pageSize: pageSize
    )
  }

  var pageCount: Int {
    SessionTimelinePagination.pageCount(for: totalCount, pageSize: pageSize)
  }

  var rangeText: String {
    if totalCount == 0 {
      return isLoading ? "Loading latest activity" : "Showing 0-0 of 0"
    }

    // While loading, advertise the intended window so placeholders and pagination
    // read as a coherent waiting state. When idle, mirror what is actually on
    // screen so the header never claims rows the list body cannot render.
    if !isLoading, entries.isEmpty {
      return "Showing 0-0 of \(totalCount)"
    }

    return "Showing \(visibleRange.lowerBound + 1)-\(visibleRange.upperBound) of \(totalCount)"
  }

  var pageStatusText: String {
    "Page \(resolvedCurrentPage + 1) of \(pageCount)"
  }

  var showsPagination: Bool {
    pageCount > 1
  }

  /// True when metadata claims entries exist but none have landed in memory and
  /// no fetch is in flight. The view uses this to trigger a page-zero reload so
  /// stale "Showing 0-0 of N" cards self-heal instead of waiting for the user
  /// to change page size or reselect the session.
  var needsRefresh: Bool {
    !isLoading && totalCount > 0 && entries.isEmpty
  }

  var entries: [TimelineEntry] {
    guard loadedCount > visibleRange.lowerBound else {
      return []
    }

    let loadedUpperBound = min(visibleRange.upperBound, loadedCount)
    return Array(timeline[visibleRange.lowerBound..<loadedUpperBound])
  }

  var placeholderCount: Int {
    guard isLoading else {
      return 0
    }

    if totalCount == 0 {
      return pageSize
    }

    return max(0, visibleRange.count - entries.count)
  }

  private var visibleRange: Range<Int> {
    let lowerBound = resolvedCurrentPage * pageSize
    let upperBound = min(totalCount, lowerBound + pageSize)
    return lowerBound..<upperBound
  }
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
