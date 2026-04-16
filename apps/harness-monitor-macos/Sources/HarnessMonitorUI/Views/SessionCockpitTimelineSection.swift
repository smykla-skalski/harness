import HarnessMonitorKit
import SwiftUI

enum SessionTimelinePlaceholderShimmer {
  static let cycleDuration: TimeInterval = 1.15
  private static let leadingPhase: CGFloat = -0.6
  private static let trailingPhase: CGFloat = 1.8

  static func shouldAnimate(reduceMotion: Bool, placeholderCount: Int) -> Bool {
    !reduceMotion && placeholderCount > 0
  }

  static func phase(at date: Date) -> CGFloat {
    let cycleProgress =
      date.timeIntervalSinceReferenceDate
      .truncatingRemainder(dividingBy: cycleDuration)
      / cycleDuration
    return leadingPhase + ((trailingPhase - leadingPhase) * cycleProgress)
  }

  static var restingPhase: CGFloat {
    0
  }
}

struct SessionCockpitTimelineSection: View {
  let sessionID: String
  let timeline: [TimelineEntry]
  let timelineWindow: TimelineWindowResponse?
  let isTimelineLoading: Bool
  let loadPage: @Sendable (_ page: Int, _ pageSize: Int) async -> Void
  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @State private var currentPage = 0
  @State private var pageSize = SessionTimelinePageSize.defaultSize

  private var presentation: SessionTimelinePresentation {
    SessionTimelinePresentation(
      timeline: timeline,
      timelineWindow: timelineWindow,
      currentPage: currentPage,
      pageSize: pageSize.rawValue,
      isLoading: isTimelineLoading
    )
  }

  private var currentEntries: [TimelineEntry] { presentation.entries }

  private var placeholderCount: Int { presentation.placeholderCount }

  private var pageCount: Int { presentation.pageCount }

  private var resolvedCurrentPage: Int { presentation.resolvedCurrentPage }

  private var pageStatusText: String { presentation.pageStatusText }

  private var pageRangeText: String { presentation.rangeText }

  private var showsPagination: Bool { presentation.showsPagination }

  private var contentIdentity: SessionTimelineContentIdentity {
    SessionTimelineContentIdentity(
      sessionID: sessionID,
      pageSize: pageSize.rawValue,
      currentPage: resolvedCurrentPage
    )
  }

  private var pageChangeAnimation: Animation? {
    reduceMotion ? nil : .snappy(duration: 0.22, extraBounce: 0)
  }

  private var shouldAnimatePlaceholders: Bool {
    SessionTimelinePlaceholderShimmer.shouldAnimate(
      reduceMotion: reduceMotion,
      placeholderCount: placeholderCount
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      Text("Timeline")
        .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      if presentation.totalCount == 0 && isTimelineLoading == false {
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

          placeholderAwareTimelineRows
            .id(contentIdentity)

          if showsPagination {
            SessionTimelinePaginationFooter(
              currentPage: resolvedCurrentPage,
              pageCount: pageCount,
              pageStatusText: pageStatusText,
              visiblePages: SessionTimelinePagination.visiblePages(
                currentPage: resolvedCurrentPage,
                pageCount: pageCount
              ),
              goToPreviousPage: { changePage(to: resolvedCurrentPage - 1) },
              goToNextPage: { changePage(to: resolvedCurrentPage + 1) },
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
          updateCurrentPageIfNeeded(0, animated: false)
          requestVisiblePageIfNeeded(page: 0)
        }
        .onChange(of: pageSize) { oldPageSize, newPageSize in
          let rebasedPage = SessionTimelinePagination.rebasedPage(
            currentPage,
            itemCount: presentation.totalCount,
            oldPageSize: oldPageSize.rawValue,
            newPageSize: newPageSize.rawValue
          )
          updateCurrentPageIfNeeded(rebasedPage, animated: true)
          requestVisiblePageIfNeeded(page: rebasedPage)
        }
        .onChange(of: timeline.count) { _, _ in
          requestVisiblePageIfNeeded(page: resolvedCurrentPage)
        }
        .onChange(of: presentation.needsRefresh, initial: true) { _, needsRefresh in
          // Safety net: if metadata reports entries but the list arrived empty
          // (stale cache/window survived an entry wipe, daemon responded with
          // an unchanged revision while we had nothing loaded, etc.) reload
          // the page so the user never sees a frozen "Showing 0-0 of N" card.
          guard needsRefresh else { return }
          requestVisiblePageIfNeeded(page: resolvedCurrentPage)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder private var placeholderAwareTimelineRows: some View {
    if shouldAnimatePlaceholders {
      TimelineView(.periodic(from: .now, by: 1 / 12)) { context in
        timelineRows(shimmerPhase: SessionTimelinePlaceholderShimmer.phase(at: context.date))
      }
    } else {
      timelineRows(shimmerPhase: SessionTimelinePlaceholderShimmer.restingPhase)
    }
  }

  private func timelineRows(shimmerPhase: CGFloat) -> some View {
    LazyVStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      ForEach(currentEntries) { entry in
        SessionCockpitTimelineEntryRow(
          entry: entry,
          dateTimeConfiguration: dateTimeConfiguration
        )
      }

      ForEach(Array(0..<placeholderCount), id: \.self) { index in
        SessionCockpitTimelinePlaceholderRow(
          seed: index,
          shimmerPhase: shimmerPhase,
          showsShimmer: shouldAnimatePlaceholders
        )
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

    updateCurrentPageIfNeeded(clampedPage, animated: true)
    requestVisiblePageIfNeeded(page: clampedPage)
  }

  private func updateCurrentPageIfNeeded(_ page: Int, animated: Bool) {
    guard page != currentPage else {
      return
    }

    if animated, let pageChangeAnimation {
      withAnimation(pageChangeAnimation) {
        currentPage = page
      }
    } else {
      currentPage = page
    }
  }

  private func requestVisiblePageIfNeeded(page: Int) {
    let targetPage = SessionTimelinePagination.clampedPage(
      page,
      itemCount: presentation.totalCount,
      pageSize: pageSize.rawValue
    )
    guard targetPage >= 0 else {
      return
    }

    Task {
      await loadPage(targetPage, pageSize.rawValue)
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
      Text(formatTimelineTimestamp(entry.recordedAt, configuration: dateTimeConfiguration))
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
  }
}

private struct SessionCockpitTimelinePlaceholderRow: View {
  let seed: Int
  let shimmerPhase: CGFloat
  let showsShimmer: Bool
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  private var summaryWidth: CGFloat {
    let widths: [CGFloat] = [220, 264, 198, 242]
    return widths[seed % widths.count]
  }

  private var kindWidth: CGFloat {
    let widths: [CGFloat] = [54, 66, 58]
    return widths[seed % widths.count]
  }

  var body: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.sectionSpacing) {
      shimmerBar(width: 6, height: 18, opacity: 0.18)
        .clipShape(
          RoundedRectangle(cornerRadius: 3, style: .continuous)
        )
      shimmerBar(width: 108)
      shimmerBar(width: summaryWidth)
        .frame(maxWidth: .infinity, alignment: .leading)
      shimmerBar(width: kindWidth)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(HarnessMonitorTheme.cardPadding)
    .background {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
        .fill(.primary.opacity(0.03))
    }
    .overlay {
      if showsShimmer {
        shimmerOverlay
          .clipShape(
            RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
          )
      }
    }
    .accessibilityHidden(true)
  }

  private func shimmerBar(width: CGFloat, height: CGFloat = 12, opacity: Double = 0.08) -> some View
  {
    RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
      .fill(.primary.opacity(opacity))
      .frame(width: width, height: height)
  }

  private var shimmerOverlay: some View {
    GeometryReader { proxy in
      LinearGradient(
        colors: [
          .clear,
          .white.opacity(0.05),
          .white.opacity(0.22),
          .clear,
        ],
        startPoint: .leading,
        endPoint: .trailing
      )
      .frame(width: proxy.size.width * 0.46)
      .offset(
        x: reduceMotion || showsShimmer == false
          ? 0
          : proxy.size.width * shimmerPhase
      )
      .blendMode(.plusLighter)
    }
  }
}

#Preview("Timeline Pagination") {
  SessionCockpitTimelineSection(
    sessionID: PreviewFixtures.summary.sessionId,
    timeline: PreviewFixtures.pagedTimeline,
    timelineWindow: .fallbackMetadata(for: PreviewFixtures.pagedTimeline),
    isTimelineLoading: false,
    loadPage: { _, _ in }
  )
  .padding()
  .frame(width: 960)
}

#Preview("Timeline") {
  SessionCockpitTimelineSection(
    sessionID: PreviewFixtures.summary.sessionId,
    timeline: PreviewFixtures.timeline,
    timelineWindow: .fallbackMetadata(for: PreviewFixtures.timeline),
    isTimelineLoading: false,
    loadPage: { _, _ in }
  )
  .padding()
  .frame(width: 960)
}
