import AppKit
import HarnessMonitorKit
import SwiftUI

struct ToolCallTimelineView: View {
  let entries: [TimelineEntry]
  let liveAnnouncementRowIDs: Set<String>
  let overflowNotice: HarnessMonitorStore.ToolCallTimelineOverflowNotice?

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
  }

  private var presentation: ToolCallTimelinePresentation {
    Self.materialisePresentation(from: entries)
  }

  private var announcementSnapshot: ToolCallTimelineAnnouncementSnapshot {
    ToolCallTimelineAnnouncementSnapshot(
      rows: presentation.rows,
      liveRowIDs: liveAnnouncementRowIDs
    )
  }

  private var visibleOverflowToolCallCount: Int {
    presentation.rows.filter { liveAnnouncementRowIDs.contains($0.id) }.count
  }

  private var overflowAnnouncement: ToolCallTimelineOverflowAnnouncement? {
    guard let overflowNotice else {
      return nil
    }
    return ToolCallTimelineOverflowAnnouncement(
      id: overflowNotice.recordedAt,
      text: Self.overflowNoticeText(
        rawUpdateCount: overflowNotice.rawUpdateCount,
        visibleToolCallCount: max(overflowNotice.displayedEventCount, visibleOverflowToolCallCount)
      )
    )
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
          visibleToolCallCount: max(
            overflowNotice.displayedEventCount, visibleOverflowToolCallCount)
        )
      }
      if presentation.rows.isEmpty {
        Text("No activity yet.")
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      } else {
        LazyVStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
          ForEach(presentation.sections) { section in
            ToolCallTimelineSectionView(section: section)
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
    .onChange(of: announcementSnapshot) { oldValue, newValue in
      announceToolCallStateChanges(
        from: oldValue,
        to: newValue
      )
    }
    .onChange(of: overflowAnnouncement) { oldValue, newValue in
      guard let newValue, newValue != oldValue else {
        return
      }
      AccessibilityNotification.Announcement(newValue.text).post()
    }
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
}

struct ToolCallTimelineAnnouncementSnapshot: Equatable {
  let rows: [ToolCallTimelineRow]
  let liveRowIDs: Set<String>

  var statusesByRowID: [String: ToolCallTimelineRow.Status] {
    Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.status) })
  }
}
