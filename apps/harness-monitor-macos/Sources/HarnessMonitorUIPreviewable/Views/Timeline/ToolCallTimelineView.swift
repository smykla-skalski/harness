import AppKit
import HarnessMonitorKit
import OSLog
import SwiftUI

let toolCallTimelinePresentationWorker = ToolCallTimelinePresentationWorker()

struct ToolCallTimelineView: View {
  let entries: [TimelineEntry]
  let liveAnnouncementRowIDs: Set<String>
  let overflowNotice: HarnessMonitorStore.ToolCallTimelineOverflowNotice?
  @State private var cachedPresentation = ToolCallTimelinePresentation.empty
  @State private var cachedVirtualizedLayout = ToolCallTimelineVirtualizedLayout.empty
  @State private var cachedAnnouncementSnapshot = ToolCallTimelineAnnouncementSnapshot.empty
  @State private var cachedScrollMetrics = ToolCallTimelineScrollMetrics.zero
  @State private var cachedOverflowAnnouncement: ToolCallTimelineOverflowAnnouncement?
  @State private var cachedRowFrames: [String: CGRect] = [:]
  @State private var presentationGeneration: UInt64 = 0
  @State private var scrollMetricsDeferrer = ToolCallTimelineScrollMetricsDeferrer()

  @AppStorage(
    HarnessMonitorToolCallAnnouncementSettings.verboseAnnouncementsKey
  )
  var verboseToolCallAnnouncements =
    HarnessMonitorToolCallAnnouncementSettings.verboseAnnouncementsDefault

  init(
    entries: [TimelineEntry],
    liveAnnouncementRowIDs: Set<String> = [],
    overflowNotice: HarnessMonitorStore.ToolCallTimelineOverflowNotice? = nil
  ) {
    self.entries = entries
    self.liveAnnouncementRowIDs = liveAnnouncementRowIDs
    self.overflowNotice = overflowNotice
    _cachedPresentation = State(initialValue: .empty)
    _cachedVirtualizedLayout = State(initialValue: .empty)
    _cachedAnnouncementSnapshot = State(initialValue: .empty)
    if let overflowNotice {
      _cachedOverflowAnnouncement = State(
        initialValue: ToolCallTimelineOverflowAnnouncement(
          id: overflowNotice.recordedAt,
          text: Self.overflowNoticeText(
            rawUpdateCount: overflowNotice.rawUpdateCount,
            visibleToolCallCount: overflowNotice.displayedEventCount
          )
        )
      )
    } else {
      _cachedOverflowAnnouncement = State(initialValue: nil)
    }
  }

  var presentationInput: ToolCallTimelinePresentationInput {
    ToolCallTimelinePresentationInput(
      entries: entries,
      liveAnnouncementRowIDs: liveAnnouncementRowIDs,
      overflowNotice: overflowNotice,
      scrollMetrics: cachedScrollMetrics
    )
  }

  var presentationTaskKey: ToolCallTimelinePresentationTaskKey {
    ToolCallTimelinePresentationTaskKey(
      entries: entries,
      liveAnnouncementRowIDs: liveAnnouncementRowIDs,
      overflowNotice: overflowNotice,
      scrollMetrics: cachedScrollMetrics
    )
  }

  var overflowToolCallCount: Int {
    overflowNotice?.displayedEventCount ?? visibleOverflowToolCallCount
  }

  var visibleOverflowToolCallCount: Int {
    let viewportVisibleRowIDs = Self.viewportVisibleRowIDs(
      renderedRowIDs: cachedVirtualizedLayout.renderedRowIDs,
      rowFrames: cachedRowFrames,
      visibleRect: cachedScrollMetrics.visibleRect
    )
    return viewportVisibleRowIDs.reduce(into: 0) { count, rowID in
      if liveAnnouncementRowIDs.contains(rowID) {
        count += 1
      }
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      HStack {
        Text("Action history")
          .scaledFont(.headline)
          .accessibilityAddTraits(.isHeader)
        Spacer()
      }
      if let overflowNotice {
        ToolCallTimelineOverflowNoticeView(
          rawUpdateCount: overflowNotice.rawUpdateCount,
          displayedToolCallCount: overflowToolCallCount,
          visibleToolCallCount: visibleOverflowToolCallCount
        )
      }
      if cachedPresentation.rows.isEmpty {
        Text("No activity yet")
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
            if cachedVirtualizedLayout.topSpacerHeight > 0 {
              Color.clear
                .frame(height: cachedVirtualizedLayout.topSpacerHeight)
            }

            ForEach(cachedVirtualizedLayout.sections) { section in
              ToolCallTimelineSectionView(section: section)
            }

            if cachedVirtualizedLayout.bottomSpacerHeight > 0 {
              Color.clear
                .frame(height: cachedVirtualizedLayout.bottomSpacerHeight)
            }
          }
          .scrollTargetLayout()
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .coordinateSpace(name: ToolCallTimelineScrollMetrics.coordinateSpaceName)
        .scrollIndicators(.visible)
        .frame(minHeight: 180, idealHeight: 260, maxHeight: 360)
        .onScrollGeometryChange(
          for: ToolCallTimelineScrollMetrics.self,
          of: ToolCallTimelineScrollMetrics.init(geometry:)
        ) { oldValue, newValue in
          let oldBucket = ToolCallTimelineVirtualizedLayout.scrollBucket(for: oldValue)
          let newBucket = ToolCallTimelineVirtualizedLayout.scrollBucket(for: newValue)
          let needsInitialMetrics = cachedScrollMetrics.viewportHeight == 0
          let viewportHeightChanged =
            abs(cachedScrollMetrics.viewportHeight - newValue.viewportHeight) > 0.5
          guard needsInitialMetrics || viewportHeightChanged || oldBucket != newBucket else {
            return
          }
          scheduleScrollMetricsUpdate(newValue)
        }
        .onScrollPhaseChange { _, newPhase, context in
          guard newPhase == .idle else {
            return
          }
          scheduleScrollMetricsUpdate(ToolCallTimelineScrollMetrics(geometry: context.geometry))
        }
        .onPreferenceChange(ToolCallTimelineRowFramePreferenceKey.self) { newFrames in
          if cachedRowFrames != newFrames {
            cachedRowFrames = newFrames
          }
        }
      }
    }
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
    .accessibilityElement(children: .contain)
    .accessibilityLiveRegion(.polite)
    .accessibilityIdentifier(HarnessMonitorAccessibility.toolCallTimeline)
    .overlay {
      AccessibilityTextMarker(
        identifier: HarnessMonitorAccessibility.toolCallTimelineAccessibilityState,
        text: Self.accessibilityStateMarkerText
      )
    }
    .task(id: presentationTaskKey) {
      await rebuildCachedPresentation()
    }
    .onChange(of: cachedAnnouncementSnapshot) { oldValue, newValue in
      announceToolCallStateChanges(
        from: oldValue,
        to: newValue
      )
    }
    .onChange(of: cachedOverflowAnnouncement) { oldValue, newValue in
      guard let newValue, newValue != oldValue else {
        return
      }
      AccessibilityNotification.Announcement(newValue.text).post()
    }
  }

  @MainActor
  func rebuildCachedPresentation() async {
    presentationGeneration &+= 1
    let generation = presentationGeneration
    let input = presentationInput
    let output = await toolCallTimelinePresentationWorker.compute(input: input)
    guard !Task.isCancelled, presentationGeneration == generation else {
      return
    }
    if cachedPresentation != output.presentation {
      cachedPresentation = output.presentation
    }
    if cachedVirtualizedLayout != output.layout {
      cachedVirtualizedLayout = output.layout
    }
    if cachedAnnouncementSnapshot != output.announcementSnapshot {
      cachedAnnouncementSnapshot = output.announcementSnapshot
    }
    if cachedOverflowAnnouncement != output.overflowAnnouncement {
      cachedOverflowAnnouncement = output.overflowAnnouncement
    }
  }

  func scheduleScrollMetricsUpdate(_ scrollMetrics: ToolCallTimelineScrollMetrics) {
    scrollMetricsDeferrer.schedule(scrollMetrics) { latestMetrics in
      guard cachedScrollMetrics != latestMetrics else {
        return
      }
      cachedScrollMetrics = latestMetrics
    }
  }

  nonisolated static func viewportVisibleRowIDs(
    renderedRowIDs: Set<String>,
    rowFrames: [String: CGRect],
    visibleRect: CGRect
  ) -> Set<String> {
    Set(
      renderedRowIDs.filter { rowID in
        guard let frame = rowFrames[rowID] else {
          return false
        }
        return frame.intersects(visibleRect)
      }
    )
  }

  static func materialiseRows(from entries: [TimelineEntry]) -> [ToolCallTimelineRow] {
    materialisePresentation(from: entries).rows
  }

  nonisolated static func materialisePresentation(
    from entries: [TimelineEntry]
  ) -> ToolCallTimelinePresentation {
    let sortedRows =
      entries
      .compactMap(ToolCallTimelineRow.init(entry:))
      .sorted(by: rowSortOrder)
    var rowsByID: [String: ToolCallTimelineRow] = [:]

    for row in sortedRows {
      guard let existingRow = rowsByID[row.id] else {
        rowsByID[row.id] = row
        continue
      }
      rowsByID[row.id] = existingRow.merging(row)
    }

    let rows = rowsByID.values.sorted(by: reverseRowSortOrder)
    return ToolCallTimelinePresentation(sections: ToolCallTimelinePresentation.sections(for: rows))
  }

  static func shouldAnnounceToolCallStatusChange(
    previousStatus: ToolCallTimelineRow.Status?,
    row: ToolCallTimelineRow,
    verboseAnnouncements: Bool
  ) -> Bool {
    guard previousStatus != row.status else {
      return false
    }
    if verboseAnnouncements {
      return true
    }
    return row.status.isTerminal
  }

  nonisolated static func rowSortOrder(
    lhs: ToolCallTimelineRow,
    rhs: ToolCallTimelineRow
  ) -> Bool {
    if lhs.recordedAt != rhs.recordedAt {
      return lhs.recordedAt < rhs.recordedAt
    }
    if let lhsSequence = lhs.sequence,
      let rhsSequence = rhs.sequence,
      lhsSequence != rhsSequence
    {
      return lhsSequence < rhsSequence
    }
    return lhs.entryId < rhs.entryId
  }

  nonisolated static func reverseRowSortOrder(
    lhs: ToolCallTimelineRow,
    rhs: ToolCallTimelineRow
  ) -> Bool {
    if lhs.recordedAt != rhs.recordedAt {
      return lhs.recordedAt > rhs.recordedAt
    }
    if let lhsSequence = lhs.sequence,
      let rhsSequence = rhs.sequence,
      lhsSequence != rhsSequence
    {
      return lhsSequence > rhsSequence
    }
    return lhs.entryId < rhs.entryId
  }

  static func orderedAnnouncementRows(
    previousStates: [String: ToolCallTimelineRow.Status],
    rows: [ToolCallTimelineRow],
    liveAnnouncementRowIDs: Set<String>,
    verboseAnnouncements: Bool
  ) -> [ToolCallTimelineRow] {
    guard !liveAnnouncementRowIDs.isEmpty else {
      return []
    }
    return rows.filter { row in
      guard liveAnnouncementRowIDs.contains(row.id) else {
        return false
      }
      return shouldAnnounceToolCallStatusChange(
        previousStatus: previousStates[row.id],
        row: row,
        verboseAnnouncements: verboseAnnouncements
      )
    }
  }

  nonisolated static func overflowNoticeText(
    rawUpdateCount: Int,
    visibleToolCallCount: Int
  ) -> String {
    """
    The latest ACP burst condensed \(rawUpdateCount) raw updates into \
    \(visibleToolCallCount) visible tool calls. Older activity is omitted here.
    """
  }

  static func sectionAccessibilityLabel(title: String, capabilityTags: [String]) -> String {
    guard !capabilityTags.isEmpty else {
      return title
    }
    return "\(title). Capabilities: \(capabilityTags.joined(separator: ", "))"
  }

  static var accessibilityStateMarkerText: String {
    "live-region=polite"
  }

  func announceToolCallStateChanges(
    from oldValue: ToolCallTimelineAnnouncementSnapshot,
    to newValue: ToolCallTimelineAnnouncementSnapshot
  ) {
    for row in Self.orderedAnnouncementRows(
      previousStates: oldValue.statusesByRowID,
      rows: newValue.rows,
      liveAnnouncementRowIDs: newValue.liveRowIDs,
      verboseAnnouncements: verboseToolCallAnnouncements
    ).reversed() {
      AccessibilityNotification.Announcement(row.announcementText).post()
    }
  }
}
