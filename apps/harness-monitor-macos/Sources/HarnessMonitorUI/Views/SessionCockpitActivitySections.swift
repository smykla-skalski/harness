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
                let effectiveStatus = signal.effectiveStatus
                Text(effectiveStatus.title)
                  .scaledFont(.caption.bold())
                  .foregroundStyle(signalStatusColor(for: effectiveStatus))
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
  @State private var pageSize = SessionTimelinePageSize.defaultSize

  private var currentEntries: [TimelineEntry] {
    SessionTimelinePagination.currentEntries(
      in: timeline,
      currentPage: resolvedCurrentPage,
      pageSize: pageSize.rawValue
    )
  }

  private var pageCount: Int {
    SessionTimelinePagination.pageCount(for: timeline.count, pageSize: pageSize.rawValue)
  }

  private var resolvedCurrentPage: Int {
    SessionTimelinePagination.clampedPage(
      currentPage,
      itemCount: timeline.count,
      pageSize: pageSize.rawValue
    )
  }

  private var pageStatusText: String {
    "Page \(resolvedCurrentPage + 1) of \(pageCount)"
  }

  private var pageRangeText: String {
    let lowerBound = (resolvedCurrentPage * pageSize.rawValue) + 1
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
          SessionTimelinePageSummary(
            rangeText: pageRangeText,
            pageSize: $pageSize
          )

          LazyVStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
            ForEach(currentEntries) { entry in
              SessionCockpitTimelineEntryRow(
                entry: entry,
                dateTimeConfiguration: dateTimeConfiguration
              )
            }
          }
          .id("\(pageSize.rawValue)-\(resolvedCurrentPage)")
          .frame(maxWidth: .infinity, alignment: .leading)

          if showsPagination {
            SessionTimelinePaginationFooter(
              currentPage: resolvedCurrentPage,
              pageCount: pageCount,
              pageStatusText: pageStatusText,
              visiblePages: SessionTimelinePagination.visiblePages(
                currentPage: resolvedCurrentPage,
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
        .onChange(of: pageSize) { oldPageSize, newPageSize in
          setCurrentPage(
            SessionTimelinePagination.rebasedPage(
              currentPage,
              itemCount: timeline.count,
              oldPageSize: oldPageSize.rawValue,
              newPageSize: newPageSize.rawValue
            )
          )
        }
        .onChange(of: timeline) { _, newTimeline in
          currentPage = SessionTimelinePagination.clampedPage(
            currentPage,
            itemCount: newTimeline.count,
            pageSize: pageSize.rawValue
          )
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func changePage(to page: Int) {
    let clampedPage = SessionTimelinePagination.clampedPage(
      page,
      itemCount: timeline.count,
      pageSize: pageSize.rawValue
    )
    guard clampedPage != currentPage else {
      return
    }

    setCurrentPage(clampedPage)
  }

  private func setCurrentPage(_ page: Int) {
    if let pageChangeAnimation {
      withAnimation(pageChangeAnimation) {
        currentPage = page
      }
    } else {
      currentPage = page
    }
  }
}

private struct SessionTimelineEntryMarker: View {
  @ScaledMetric(relativeTo: .body)
  private var markerHeight = 18.0
  @ScaledMetric(relativeTo: .body)
  private var markerWidth = 6.0

  var body: some View {
    RoundedRectangle(cornerRadius: markerWidth / 2, style: .continuous)
      .fill(HarnessMonitorTheme.accent.opacity(0.45))
      .frame(width: markerWidth, height: markerHeight)
      .accessibilityHidden(true)
  }
}

private struct SessionCockpitTimelineEntryRow: View {
  let entry: TimelineEntry
  let dateTimeConfiguration: HarnessMonitorDateTimeConfiguration

  var body: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.sectionSpacing) {
      SessionTimelineEntryMarker()
      Text(formatTimestamp(entry.recordedAt, configuration: dateTimeConfiguration))
        .scaledFont(.caption.monospaced())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
      Text(entry.summary)
        .scaledFont(.system(.body, design: .rounded, weight: .semibold))
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
      Text(entry.kind)
        .scaledFont(.caption.monospaced())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
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
