import HarnessMonitorKit
import SwiftUI

struct SessionCockpitSignalsSection: View {
  let signals: [SessionSignalRecord]
  let isExtensionsLoading: Bool
  let inspectSignal: (String) -> Void
  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      HStack(alignment: .center, spacing: HarnessMonitorTheme.sectionSpacing) {
        Text("Signals")
          .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
          .accessibilityAddTraits(.isHeader)
          .opacity(signals.isEmpty && !isExtensionsLoading ? 0.55 : 1)
        Spacer(minLength: 0)
        if signals.isEmpty && !isExtensionsLoading {
          Text("No signals yet")
            .scaledFont(.system(.body, design: .rounded))
            .foregroundStyle(.tertiary)
            .opacity(0.75)
        }
      }
      LazyVStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
        ForEach(signals) { signal in
          Button {
            inspectSignal(signal.signal.signalId)
          } label: {
            HStack(alignment: .top) {
              VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
                Text(signal.signal.command)
                  .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
                Text(signal.signal.payload.message)
                  .scaledFont(.subheadline)
                  .foregroundStyle(HarnessMonitorTheme.secondaryInk)
                  .multilineTextAlignment(.leading)
              }
              Spacer()
              VStack(alignment: .trailing, spacing: HarnessMonitorTheme.itemSpacing) {
                Text(signal.status.title)
                  .scaledFont(.caption.bold())
                  .foregroundStyle(signalStatusColor(for: signal.status))
                Text(formatTimestamp(signal.signal.createdAt, configuration: dateTimeConfiguration))
                  .scaledFont(.caption.monospaced())
                  .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(HarnessMonitorTheme.cardPadding)
          }
          .harnessInteractiveCardButtonStyle()
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.sessionSignalCard(signal.signal.signalId)
          )
          .contextMenu {
            Button {
              inspectSignal(signal.signal.signalId)
            } label: {
              Label("Inspect", systemImage: "info.circle")
            }
            Divider()
            Button {
              HarnessMonitorClipboard.copy(signal.signal.signalId)
            } label: {
              Label("Copy Signal ID", systemImage: "doc.on.doc")
            }
          }
          .transition(
            .asymmetric(
              insertion: .scale(scale: 0.95).combined(with: .opacity),
              removal: .opacity
            ))
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

#Preview("Signals") {
  SessionCockpitSignalsSection(
    signals: PreviewFixtures.signals,
    isExtensionsLoading: false,
    inspectSignal: { _ in }
  )
  .padding()
  .frame(width: 960)
}

struct SessionCockpitTimelineSection: View {
  let sessionID: String
  let timeline: [TimelineEntry]
  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @State private var currentPage = 0

  private var currentEntries: [TimelineEntry] {
    SessionTimelinePagination.currentEntries(
      in: timeline,
      currentPage: currentPage
    )
  }

  private var pageCount: Int {
    SessionTimelinePagination.pageCount(for: timeline.count)
  }

  private var pageStatusText: String {
    "Page \(currentPage + 1) of \(pageCount)"
  }

  private var pageRangeText: String {
    let lowerBound = (currentPage * SessionTimelinePagination.pageSize) + 1
    let upperBound = min(lowerBound + currentEntries.count - 1, timeline.count)
    return "Showing \(lowerBound)-\(upperBound) of \(timeline.count)"
  }

  private var showsPagination: Bool {
    pageCount > 1
  }

  private var pageChangeAnimation: Animation? {
    reduceMotion ? nil : .snappy(duration: 0.22, extraBounce: 0)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      Text("Timeline")
        .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      if timeline.isEmpty {
        ContentUnavailableView {
          Label("No activity yet", systemImage: "clock")
        } description: {
          Text("Timeline entries appear as agents work on tasks.")
        }
        .frame(maxWidth: .infinity)
      } else {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingLG) {
          SessionTimelinePageSummary(rangeText: pageRangeText)

          LazyVStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
            ForEach(currentEntries) { entry in
              SessionCockpitTimelineEntryRow(
                entry: entry,
                dateTimeConfiguration: dateTimeConfiguration
              )
            }
          }
          .id(currentPage)
          .frame(maxWidth: .infinity, alignment: .leading)

          if showsPagination {
            Divider()
              .overlay(HarnessMonitorTheme.controlBorder.opacity(0.55))

            SessionTimelinePaginationFooter(
              currentPage: currentPage,
              pageCount: pageCount,
              pageStatusText: pageStatusText,
              visiblePages: SessionTimelinePagination.visiblePages(
                currentPage: currentPage,
                pageCount: pageCount
              ),
              goToPreviousPage: { changePage(to: currentPage - 1) },
              goToNextPage: { changePage(to: currentPage + 1) },
              goToPage: changePage(to:)
            )
            .accessibilityIdentifier(HarnessMonitorAccessibility.sessionTimelinePagination)
          }
        }
        .padding(HarnessMonitorTheme.spacingLG)
        .background {
          RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusLG, style: .continuous)
            .fill(.primary.opacity(0.035))
            .overlay {
              RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusLG, style: .continuous)
                .stroke(HarnessMonitorTheme.controlBorder.opacity(0.55), lineWidth: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: sessionID) { _, _ in
          currentPage = 0
        }
        .onChange(of: timeline) { _, newTimeline in
          currentPage = SessionTimelinePagination.clampedPage(
            currentPage,
            itemCount: newTimeline.count
          )
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func changePage(to page: Int) {
    let clampedPage = SessionTimelinePagination.clampedPage(page, itemCount: timeline.count)
    guard clampedPage != currentPage else {
      return
    }

    if let pageChangeAnimation {
      withAnimation(pageChangeAnimation) {
        currentPage = clampedPage
      }
    } else {
      currentPage = clampedPage
    }
  }
}

private struct SessionTimelinePageSummary: View {
  let rangeText: String

  var body: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.itemSpacing) {
      Text("Visible Events")
        .scaledFont(.caption.weight(.semibold))
        .tracking(HarnessMonitorTheme.uppercaseTracking)
        .foregroundStyle(HarnessMonitorTheme.ink)

      Spacer(minLength: 0)

      Text(rangeText)
        .scaledFont(.caption.monospaced())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
  }
}

private struct SessionCockpitTimelineEntryRow: View {
  let entry: TimelineEntry
  let dateTimeConfiguration: HarnessMonitorDateTimeConfiguration

  var body: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.sectionSpacing) {
      RoundedRectangle(cornerRadius: 999)
        .fill(HarnessMonitorTheme.accent.opacity(0.35))
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
      Text(entry.summary)
        .scaledFont(.system(.body, design: .rounded, weight: .semibold))
        .lineLimit(1)
      Spacer()
      Text(
        "\(entry.kind) • "
          + "\(formatTimestamp(entry.recordedAt, configuration: dateTimeConfiguration))"
      )
      .scaledFont(.caption.monospaced())
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      .lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .center)
    .padding(HarnessMonitorTheme.cardPadding)
    .background {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
        .fill(.primary.opacity(0.04))
    }
    .contextMenu {
      Button {
        HarnessMonitorClipboard.copy(entry.summary)
      } label: {
        Label("Copy Summary", systemImage: "doc.on.doc")
      }
      if let taskID = entry.taskId {
        Button {
          HarnessMonitorClipboard.copy(taskID)
        } label: {
          Label("Copy Task ID", systemImage: "doc.on.doc")
        }
      }
    }
    .transition(
      .asymmetric(
        insertion: .scale(scale: 0.95).combined(with: .opacity),
        removal: .opacity
      )
    )
  }
}

private struct SessionTimelinePaginationFooter: View {
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
      .harnessActionButtonStyle(variant: .bordered, tint: controlTint)
      .controlSize(HarnessMonitorControlMetrics.compactControlSize)
      .disabled(currentPage == 0)
      .accessibilityIdentifier(HarnessMonitorAccessibility.sessionTimelinePaginationPrevious)

      if visiblePages.first != .zero {
        Text("…")
          .scaledFont(.caption.monospaced())
          .foregroundStyle(controlTint)
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
        .harnessActionButtonStyle(
          variant: page == currentPage ? .prominent : .bordered,
          tint: page == currentPage ? HarnessMonitorTheme.accent : controlTint
        )
        .fontWeight(page == currentPage ? .bold : .semibold)
        .controlSize(HarnessMonitorControlMetrics.compactControlSize)
        .accessibilityLabel("Page \(page + 1)")
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.sessionTimelinePaginationPageButton(page + 1)
        )
      }

      if visiblePages.last != pageCount - 1 {
        Text("…")
          .scaledFont(.caption.monospaced())
          .foregroundStyle(controlTint)
          .accessibilityHidden(true)
      }

      Button(action: goToNextPage) {
        Label("Next", systemImage: "chevron.right")
      }
      .harnessActionButtonStyle(variant: .bordered, tint: controlTint)
      .controlSize(HarnessMonitorControlMetrics.compactControlSize)
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

private enum SessionTimelinePagination {
  static let pageSize = 15
  private static let maxVisiblePageButtons = 5

  static func clampedPage(_ page: Int, itemCount: Int) -> Int {
    let resolvedPageCount = pageCount(for: itemCount)
    guard resolvedPageCount > 0 else {
      return 0
    }

    return min(max(page, 0), resolvedPageCount - 1)
  }

  static func currentEntries(
    in timeline: [TimelineEntry],
    currentPage: Int
  ) -> [TimelineEntry] {
    let clampedCurrentPage = clampedPage(currentPage, itemCount: timeline.count)
    let startIndex = clampedCurrentPage * pageSize
    let endIndex = min(startIndex + pageSize, timeline.count)
    return Array(timeline[startIndex..<endIndex])
  }

  static func pageCount(for itemCount: Int) -> Int {
    max(1, Int(ceil(Double(itemCount) / Double(pageSize))))
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

#Preview("Timeline Pagination") {
  SessionCockpitTimelineSection(
    sessionID: PreviewFixtures.summary.sessionId,
    timeline: PreviewFixtures.pagedTimeline
  )
  .padding()
  .frame(width: 960)
}

#Preview("Timeline") {
  SessionCockpitTimelineSection(
    sessionID: PreviewFixtures.summary.sessionId,
    timeline: PreviewFixtures.timeline
  )
  .padding()
  .frame(width: 960)
}
