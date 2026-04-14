import HarnessMonitorKit
import SwiftUI

struct SessionTimelinePageSizePicker: View {
  @Binding var pageSize: SessionTimelinePageSize

  var body: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.itemSpacing) {
      Text("Per Page")
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.ink)
        .accessibilityHidden(true)

      Picker("Events per page", selection: $pageSize) {
        ForEach(SessionTimelinePageSize.allCases) { option in
          Text(option.label).tag(option)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .frame(width: 68)
      .harnessNativeFormControl()
      .accessibilityLabel("Events per page")
      .accessibilityIdentifier(HarnessMonitorAccessibility.sessionTimelinePageSizePicker)
    }
  }
}

struct SessionTimelinePageSummary: View {
  let rangeText: String
  @Binding var pageSize: SessionTimelinePageSize

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: HarnessMonitorTheme.itemSpacing) {
        rangeTextLabel
        Spacer(minLength: 0)
        SessionTimelinePageSizePicker(pageSize: $pageSize)
      }

      VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
        rangeTextLabel
        SessionTimelinePageSizePicker(pageSize: $pageSize)
      }
    }
  }

  private var rangeTextLabel: some View {
    Text(rangeText)
      .scaledFont(.caption.monospaced())
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
  }
}

struct SessionTimelinePaginationFooter: View {
  let currentPage: Int
  let pageCount: Int
  let pageStatusText: String
  let visiblePages: [Int]
  let goToPreviousPage: () -> Void
  let goToNextPage: () -> Void
  let goToPage: (Int) -> Void

  private let controlTint = HarnessMonitorTheme.ink

  var body: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.itemSpacing) {
      Text(pageStatusText)
        .scaledFont(.caption.monospaced())
        .foregroundStyle(controlTint)
        .accessibilityIdentifier(HarnessMonitorAccessibility.sessionTimelinePaginationStatus)

      Spacer(minLength: 0)

      Button(action: goToPreviousPage) {
        Label("Previous", systemImage: "chevron.left")
      }
      .buttonStyle(
        SessionTimelinePaginationButtonStyle(
          tint: controlTint,
          prominence: .regular
        )
      )
      .disabled(currentPage == 0)
      .accessibilityIdentifier(HarnessMonitorAccessibility.sessionTimelinePaginationPrevious)

      if visiblePages.first != .zero {
        Text("…")
          .scaledFont(.caption.monospaced())
          .foregroundStyle(controlTint.opacity(0.94))
          .accessibilityHidden(true)
      }

      ForEach(visiblePages, id: \.self) { page in
        Button {
          goToPage(page)
        } label: {
          Text("\(page + 1)")
            .monospacedDigit()
            .frame(minWidth: 26)
        }
        .buttonStyle(
          SessionTimelinePaginationButtonStyle(
            tint: page == currentPage ? HarnessMonitorTheme.accent : controlTint,
            prominence: page == currentPage ? .selected : .regular
          )
        )
        .fontWeight(page == currentPage ? .bold : .semibold)
        .accessibilityLabel("Page \(page + 1)")
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.sessionTimelinePaginationPageButton(page + 1)
        )
      }

      if visiblePages.last != pageCount - 1 {
        Text("…")
          .scaledFont(.caption.monospaced())
          .foregroundStyle(controlTint.opacity(0.94))
          .accessibilityHidden(true)
      }

      Button(action: goToNextPage) {
        Label("Next", systemImage: "chevron.right")
      }
      .buttonStyle(
        SessionTimelinePaginationButtonStyle(
          tint: controlTint,
          prominence: .regular
        )
      )
      .disabled(currentPage >= pageCount - 1)
      .accessibilityIdentifier(HarnessMonitorAccessibility.sessionTimelinePaginationNext)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private enum TimelinePageProminence {
  case regular
  case selected
}

private struct SessionTimelinePaginationButtonStyle: ButtonStyle {
  let tint: Color
  let prominence: TimelinePageProminence

  @ScaledMetric(relativeTo: .caption)
  private var cornerRadius = 10.0
  @ScaledMetric(relativeTo: .caption)
  private var horizontalPadding = 12.0
  @ScaledMetric(relativeTo: .caption)
  private var verticalPadding = 5.0
  @Environment(\.isEnabled)
  private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

    return configuration.label
      .foregroundStyle(foregroundColor)
      .padding(.horizontal, horizontalPadding)
      .padding(.vertical, verticalPadding)
      .background {
        shape.fill(tint.opacity(fillOpacity(isPressed: configuration.isPressed)))
      }
      .contentShape(shape)
      .scaleEffect(configuration.isPressed && isEnabled ? 0.98 : 1)
      .shadow(color: shadowColor(isPressed: configuration.isPressed), radius: 10, y: 1)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }

  private var foregroundColor: Color {
    switch prominence {
    case .regular:
      HarnessMonitorTheme.ink.opacity(isEnabled ? 0.99 : 0.78)
    case .selected:
      HarnessMonitorTheme.onContrast.opacity(isEnabled ? 1 : 0.86)
    }
  }

  private func fillOpacity(isPressed: Bool) -> Double {
    switch prominence {
    case .regular:
      if isEnabled {
        return isPressed ? 0.52 : 0.4
      }
      return 0.26
    case .selected:
      if isEnabled {
        return isPressed ? 0.98 : 0.9
      }
      return 0.7
    }
  }

  private func shadowColor(isPressed: Bool) -> Color {
    switch prominence {
    case .regular:
      return .black.opacity(isEnabled ? (isPressed ? 0.08 : 0.05) : 0.02)
    case .selected:
      return .black.opacity(isEnabled ? (isPressed ? 0.12 : 0.08) : 0.03)
    }
  }
}

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

    return "Showing \(visibleRange.lowerBound + 1)-\(visibleRange.upperBound) of \(totalCount)"
  }

  var pageStatusText: String {
    "Page \(resolvedCurrentPage + 1) of \(pageCount)"
  }

  var showsPagination: Bool {
    pageCount > 1
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
        RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusLG, style: .continuous)
          .fill(.primary.opacity(0.035))
      }
      .padding()
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
