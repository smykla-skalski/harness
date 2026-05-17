import AppKit
import HarnessMonitorKit
import OSLog
import SwiftUI

private let toolCallTimelinePresentationWorker = ToolCallTimelinePresentationWorker()

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
  @State private var presentationGeneration: UInt64 = 0

  @AppStorage(
    HarnessMonitorToolCallAnnouncementSettings.verboseAnnouncementsKey
  )
  private var verboseToolCallAnnouncements =
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
    _cachedVisibleOverflowToolCallCount = State(initialValue: 0)
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

  private var presentationInput: ToolCallTimelinePresentationInput {
    ToolCallTimelinePresentationInput(
      entries: entries,
      liveAnnouncementRowIDs: liveAnnouncementRowIDs,
      overflowNotice: overflowNotice,
      scrollMetrics: cachedScrollMetrics,
      rowFrames: cachedRowFrames
    )
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
    .task(id: presentationInput) {
      await rebuildCachedPresentation(for: presentationInput)
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
  private func rebuildCachedPresentation(for input: ToolCallTimelinePresentationInput) async {
    presentationGeneration &+= 1
    let generation = presentationGeneration
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
    if cachedVisibleOverflowToolCallCount != output.visibleOverflowToolCallCount {
      cachedVisibleOverflowToolCallCount = output.visibleOverflowToolCallCount
    }
    if cachedAnnouncementSnapshot != output.announcementSnapshot {
      cachedAnnouncementSnapshot = output.announcementSnapshot
    }
    if cachedOverflowAnnouncement != output.overflowAnnouncement {
      cachedOverflowAnnouncement = output.overflowAnnouncement
    }
  }

  private func visibleViewportRowIDs(in layout: ToolCallTimelineVirtualizedLayout) -> Set<String> {
    Self.viewportVisibleRowIDs(
      renderedRowIDs: layout.renderedRowIDs,
      rowFrames: cachedRowFrames,
      visibleRect: cachedScrollMetrics.visibleRect
    )
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

private struct ToolCallTimelineOverflowAnnouncement: Equatable, Sendable {
  let id: String
  let text: String
}

struct ToolCallTimelinePresentation: Equatable, Sendable {
  let sections: [ToolCallTimelineSection]

  var rows: [ToolCallTimelineRow] {
    sections.flatMap(\.rows)
  }

  static let empty = Self(sections: [])

  static func sections(for rows: [ToolCallTimelineRow]) -> [ToolCallTimelineSection] {
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
    return sections
  }
}

struct ToolCallTimelineAnnouncementSnapshot: Equatable, Sendable {
  let rows: [ToolCallTimelineRow]
  let liveRowIDs: Set<String>

  var statusesByRowID: [String: ToolCallTimelineRow.Status] {
    Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.status) })
  }

  static let empty = Self(rows: [], liveRowIDs: [])
}

private struct ToolCallTimelinePresentationInput: Equatable, Sendable {
  let entries: [TimelineEntry]
  let liveAnnouncementRowIDs: Set<String>
  let overflowNotice: HarnessMonitorStore.ToolCallTimelineOverflowNotice?
  let scrollMetrics: ToolCallTimelineScrollMetrics
  let rowFrames: [String: CGRect]
}

private struct ToolCallTimelinePresentationOutput: Equatable, Sendable {
  let presentation: ToolCallTimelinePresentation
  let layout: ToolCallTimelineVirtualizedLayout
  let visibleOverflowToolCallCount: Int
  let announcementSnapshot: ToolCallTimelineAnnouncementSnapshot
  let overflowAnnouncement: ToolCallTimelineOverflowAnnouncement?
}

private actor ToolCallTimelinePresentationWorker {
  private static let signposter = OSSignposter(
    subsystem: "io.harnessmonitor",
    category: "perf"
  )
  private var cachedInput: ToolCallTimelinePresentationInput?
  private var cachedOutput = ToolCallTimelinePresentationOutput(
    presentation: .empty,
    layout: .empty,
    visibleOverflowToolCallCount: 0,
    announcementSnapshot: .empty,
    overflowAnnouncement: nil
  )

  func compute(input: ToolCallTimelinePresentationInput) -> ToolCallTimelinePresentationOutput {
    guard input != cachedInput else {
      return cachedOutput
    }
    let signpostID = Self.signposter.makeSignpostID()
    let interval = Self.signposter.beginInterval(
      "tool_call_timeline.presentation.compute",
      id: signpostID,
      "entries=\(input.entries.count, privacy: .public)"
    )
    defer {
      Self.signposter.endInterval(
        "tool_call_timeline.presentation.compute",
        interval,
        "rows=\(self.cachedOutput.presentation.rows.count, privacy: .public)"
      )
    }
    let presentation = ToolCallTimelineView.materialisePresentation(from: input.entries)
    let layout = ToolCallTimelineVirtualizedLayout(
      presentation: presentation,
      scrollMetrics: input.scrollMetrics
    )
    let viewportVisibleRowIDs = ToolCallTimelineView.viewportVisibleRowIDs(
      renderedRowIDs: layout.renderedRowIDs,
      rowFrames: input.rowFrames,
      visibleRect: input.scrollMetrics.visibleRect
    )
    let visibleOverflowToolCallCount = viewportVisibleRowIDs.reduce(into: 0) { count, rowID in
      if input.liveAnnouncementRowIDs.contains(rowID) {
        count += 1
      }
    }
    let announcementSnapshot = ToolCallTimelineAnnouncementSnapshot(
      rows: presentation.rows,
      liveRowIDs: input.liveAnnouncementRowIDs
    )
    let overflowAnnouncement: ToolCallTimelineOverflowAnnouncement? =
      if let overflowNotice = input.overflowNotice {
        ToolCallTimelineOverflowAnnouncement(
          id: overflowNotice.recordedAt,
          text: ToolCallTimelineView.overflowNoticeText(
            rawUpdateCount: overflowNotice.rawUpdateCount,
            visibleToolCallCount: overflowNotice.displayedEventCount
          )
        )
      } else {
        nil
      }
    cachedInput = input
    cachedOutput = ToolCallTimelinePresentationOutput(
      presentation: presentation,
      layout: layout,
      visibleOverflowToolCallCount: visibleOverflowToolCallCount,
      announcementSnapshot: announcementSnapshot,
      overflowAnnouncement: overflowAnnouncement
    )
    return cachedOutput
  }

  func waitForIdle() async {}
}
