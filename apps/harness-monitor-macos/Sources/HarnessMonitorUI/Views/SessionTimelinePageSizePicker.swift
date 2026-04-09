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
        SessionTimelinePageSizePicker(pageSize: $pageSize)
        Spacer(minLength: 0)
        rangeTextLabel
      }

      VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
        SessionTimelinePageSizePicker(pageSize: $pageSize)
        rangeTextLabel
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

      Spacer(minLength: 0)

      Text(pageStatusText)
        .scaledFont(.caption.monospaced())
        .foregroundStyle(controlTint)
        .accessibilityIdentifier(HarnessMonitorAccessibility.sessionTimelinePaginationStatus)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private enum SessionTimelinePaginationButtonProminence {
  case regular
  case selected
}

private struct SessionTimelinePaginationButtonStyle: ButtonStyle {
  let tint: Color
  let prominence: SessionTimelinePaginationButtonProminence

  @ScaledMetric(relativeTo: .caption)
  private var cornerRadius = 10.0
  @ScaledMetric(relativeTo: .caption)
  private var horizontalPadding = 12.0
  @ScaledMetric(relativeTo: .caption)
  private var verticalPadding = 5.0
  @Environment(\.isEnabled)
  private var isEnabled
  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast

  private var lineWidth: CGFloat {
    colorSchemeContrast == .increased ? 1.5 : 1
  }

  func makeBody(configuration: Configuration) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

    return configuration.label
      .foregroundStyle(foregroundColor)
      .padding(.horizontal, horizontalPadding)
      .padding(.vertical, verticalPadding)
      .background {
        shape.fill(tint.opacity(fillOpacity(isPressed: configuration.isPressed)))
      }
      .overlay {
        shape.strokeBorder(
          tint.opacity(strokeOpacity(isPressed: configuration.isPressed)),
          lineWidth: lineWidth
        )
      }
      .contentShape(shape)
      .scaleEffect(configuration.isPressed && isEnabled ? 0.98 : 1)
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
        return isPressed ? 0.44 : 0.32
      }
      return 0.22
    case .selected:
      if isEnabled {
        return isPressed ? 0.96 : 0.88
      }
      return 0.68
    }
  }

  private func strokeOpacity(isPressed: Bool) -> Double {
    switch prominence {
    case .regular:
      if isEnabled {
        return isPressed ? 0.82 : 0.68
      }
      return 0.46
    case .selected:
      if isEnabled {
        return isPressed ? 1 : 0.84
      }
      return 0.56
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
