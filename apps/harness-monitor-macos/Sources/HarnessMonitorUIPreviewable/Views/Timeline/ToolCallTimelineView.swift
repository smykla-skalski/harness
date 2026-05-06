import AppKit
import HarnessMonitorKit
import SwiftUI

struct ToolCallTimelineView: View {
  let entries: [TimelineEntry]
  let liveAnnouncementRowIDs: Set<String>
  let overflowNotice: HarnessMonitorStore.ToolCallTimelineOverflowNotice?
  @State private var cachedPresentation = ToolCallTimelinePresentation.empty
  @State private var cachedVirtualizedLayout = ToolCallTimelineVirtualizedLayout.empty
  @State private var cachedAnnouncementSnapshot = ToolCallTimelineAnnouncementSnapshot.empty
  @State private var cachedScrollMetrics = ToolCallTimelineScrollMetrics.zero
  @State private var cachedVisibleOverflowToolCallCount = 0
  @State private var cachedOverflowAnnouncement: ToolCallTimelineOverflowAnnouncement?
  @State private var cachedRowFrames: [String: CGRect] = [:]

  @AppStorage(
    HarnessMonitorToolCallAnnouncementPreferences.verboseAnnouncementsKey
  )
  private var verboseToolCallAnnouncements =
    HarnessMonitorToolCallAnnouncementPreferences.verboseAnnouncementsDefault

  init(
    entries: [TimelineEntry],
    liveAnnouncementRowIDs: Set<String> = [],
    overflowNotice: HarnessMonitorStore.ToolCallTimelineOverflowNotice? = nil
  ) {
    self.entries = entries
    self.liveAnnouncementRowIDs = liveAnnouncementRowIDs
    self.overflowNotice = overflowNotice
    let presentation = Self.materialisePresentation(from: entries)
    _cachedPresentation = State(initialValue: presentation)
    _cachedVirtualizedLayout = State(
      initialValue: ToolCallTimelineVirtualizedLayout(
        presentation: presentation,
        scrollMetrics: .zero
      )
    )
    _cachedAnnouncementSnapshot = State(
      initialValue: ToolCallTimelineAnnouncementSnapshot(
        rows: presentation.rows,
        liveRowIDs: liveAnnouncementRowIDs
      )
    )
    let initialVisibleCount = presentation.rows.reduce(into: 0) { count, row in
      if liveAnnouncementRowIDs.contains(row.id) {
        count += 1
      }
    }
    _cachedVisibleOverflowToolCallCount = State(initialValue: initialVisibleCount)
    if let overflowNotice {
      _cachedOverflowAnnouncement = State(
        initialValue: ToolCallTimelineOverflowAnnouncement(
          id: overflowNotice.recordedAt,
          text: Self.overflowNoticeText(
            rawUpdateCount: overflowNotice.rawUpdateCount,
            visibleToolCallCount: initialVisibleCount
          )
        )
      )
    } else {
      _cachedOverflowAnnouncement = State(initialValue: nil)
    }
  }

  private var overflowToolCallCount: Int {
    overflowNotice?.displayedEventCount ?? cachedVisibleOverflowToolCallCount
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
          visibleToolCallCount: cachedVisibleOverflowToolCallCount
        )
      }
      if cachedPresentation.rows.isEmpty {
        Text("No activity yet.")
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
        ) { _, newValue in
          guard cachedScrollMetrics != newValue else {
            return
          }
          cachedScrollMetrics = newValue
        }
        .onPreferenceChange(ToolCallTimelineRowFramePreferenceKey.self) { newFrames in
          if cachedRowFrames != newFrames {
            cachedRowFrames = newFrames
            rebuildVirtualizedLayout()
          }
        }
      }
    }
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
    .accessibilityElement(children: .contain)
    .accessibilityLiveRegion(.polite)
    .accessibilityIdentifier(HarnessMonitorAccessibility.workspaceToolCallTimeline)
    .overlay {
      AccessibilityTextMarker(
        identifier: HarnessMonitorAccessibility.toolCallTimelineAccessibilityState,
        text: Self.accessibilityStateMarkerText
      )
    }
    .onAppear {
      rebuildCachedPresentation()
    }
    .onChange(of: entries) { _, _ in
      rebuildCachedPresentation()
    }
    .onChange(of: liveAnnouncementRowIDs) { _, _ in
      rebuildCachedPresentation()
    }
    .onChange(of: overflowNotice) { _, _ in
      rebuildCachedPresentation()
    }
    .onChange(of: cachedScrollMetrics) { _, _ in
      rebuildVirtualizedLayout()
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

  private func rebuildCachedPresentation() {
    let presentation = Self.materialisePresentation(from: entries)
    if cachedPresentation != presentation {
      cachedPresentation = presentation
    }
    rebuildVirtualizedLayout()
  }

  private func rebuildVirtualizedLayout() {
    let layout = ToolCallTimelineVirtualizedLayout(
      presentation: cachedPresentation,
      scrollMetrics: cachedScrollMetrics
    )
    if cachedVirtualizedLayout != layout {
      cachedVirtualizedLayout = layout
    }
    let viewportVisibleRowIDs = visibleViewportRowIDs(in: layout)
    let visibleOverflowToolCallCount = viewportVisibleRowIDs.reduce(into: 0) { count, rowID in
      if liveAnnouncementRowIDs.contains(rowID) {
        count += 1
      }
    }
    if cachedVisibleOverflowToolCallCount != visibleOverflowToolCallCount {
      cachedVisibleOverflowToolCallCount = visibleOverflowToolCallCount
    }

    let snapshot = ToolCallTimelineAnnouncementSnapshot(
      rows: cachedPresentation.rows,
      liveRowIDs: liveAnnouncementRowIDs
    )
    if cachedAnnouncementSnapshot != snapshot {
      cachedAnnouncementSnapshot = snapshot
    }

    let overflowAnnouncement: ToolCallTimelineOverflowAnnouncement? =
      if let overflowNotice {
        ToolCallTimelineOverflowAnnouncement(
          id: overflowNotice.recordedAt,
          text: Self.overflowNoticeText(
            rawUpdateCount: overflowNotice.rawUpdateCount,
            visibleToolCallCount: overflowNotice.displayedEventCount
          )
        )
      } else {
        nil
      }
    if cachedOverflowAnnouncement != overflowAnnouncement {
      cachedOverflowAnnouncement = overflowAnnouncement
    }
  }

  private func visibleViewportRowIDs(in layout: ToolCallTimelineVirtualizedLayout) -> Set<String> {
    Self.viewportVisibleRowIDs(
      renderedRowIDs: layout.renderedRowIDs,
      rowFrames: cachedRowFrames,
      visibleRect: cachedScrollMetrics.visibleRect
    )
  }

  static func viewportVisibleRowIDs(
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

  static func materialisePresentation(
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
    var sections: [ToolCallTimelineSection] = []
    for row in rows {
      if let lastSection = sections.last,
        lastSection.canAppend(row)
      {
        sections[sections.count - 1].rows.append(row)
      } else {
        sections.append(ToolCallTimelineSection(firstRow: row))
      }
    }

    return ToolCallTimelinePresentation(
      sections: sections
    )
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

  static func overflowNoticeText(
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
    return "\(title). Capabilities: \(capabilityTags.joined(separator: ", "))."
  }

  static var accessibilityStateMarkerText: String {
    "live-region=polite"
  }

  private func announceToolCallStateChanges(
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

private struct ToolCallTimelineOverflowAnnouncement: Equatable {
  let id: String
  let text: String
}

struct ToolCallTimelinePresentation: Equatable {
  let sections: [ToolCallTimelineSection]

  var rows: [ToolCallTimelineRow] {
    sections.flatMap(\.rows)
  }

  static let empty = Self(sections: [])
}

struct ToolCallTimelineAnnouncementSnapshot: Equatable {
  let rows: [ToolCallTimelineRow]
  let liveRowIDs: Set<String>

  var statusesByRowID: [String: ToolCallTimelineRow.Status] {
    Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.status) })
  }

  static let empty = Self(rows: [], liveRowIDs: [])
}
