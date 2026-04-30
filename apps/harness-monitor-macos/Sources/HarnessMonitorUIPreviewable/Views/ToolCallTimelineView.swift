import AppKit
import HarnessMonitorKit
import SwiftUI

struct ToolCallTimelineView: View {
  let entries: [TimelineEntry]
  let liveAnnouncementRowIDs: Set<String>
  let overflowNotice: HarnessMonitorStore.ToolCallTimelineOverflowNotice?
  let stopSession: () -> Void

  @AppStorage(
    HarnessMonitorToolCallAnnouncementPreferences.verboseAnnouncementsKey
  )
  private var verboseToolCallAnnouncements =
    HarnessMonitorToolCallAnnouncementPreferences.verboseAnnouncementsDefault

  init(
    entries: [TimelineEntry],
    liveAnnouncementRowIDs: Set<String> = [],
    overflowNotice: HarnessMonitorStore.ToolCallTimelineOverflowNotice? = nil,
    stopSession: @escaping () -> Void
  ) {
    self.entries = entries
    self.liveAnnouncementRowIDs = liveAnnouncementRowIDs
    self.overflowNotice = overflowNotice
    self.stopSession = stopSession
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

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      HStack {
        Text("Tool calls")
          .scaledFont(.headline)
          .accessibilityAddTraits(.isHeader)
        Spacer()
        Button(role: .destructive, action: stopSession) {
          Label("Interrupt run", systemImage: "stop.fill")
        }
        .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.danger)
      }
      if let overflowNotice {
        ToolCallTimelineOverflowNoticeView(notice: overflowNotice)
      }
      if presentation.rows.isEmpty {
        Text("No tool calls yet.")
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
    .accessibilityIdentifier(HarnessMonitorAccessibility.toolCallTimeline)
    .onChange(of: announcementSnapshot) { oldValue, newValue in
      announceToolCallStateChanges(
        from: oldValue,
        to: newValue
      )
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

  private func announceToolCallStateChanges(
    from oldValue: ToolCallTimelineAnnouncementSnapshot,
    to newValue: ToolCallTimelineAnnouncementSnapshot
  ) {
    for row in Self.orderedAnnouncementRows(
      previousStates: oldValue.statusesByRowID,
      rows: newValue.rows,
      liveAnnouncementRowIDs: newValue.liveRowIDs,
      verboseAnnouncements: verboseToolCallAnnouncements
    ) {
      AccessibilityNotification.Announcement(row.announcementText).post()
    }
  }
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

struct ToolCallTimelineSection: Identifiable, Equatable {
  let id: String
  let acpAgentID: String?
  let agentDisplayName: String?
  let capabilityTags: [String]
  var rows: [ToolCallTimelineRow]

  init(firstRow: ToolCallTimelineRow) {
    id = "\(firstRow.acpAgentID ?? "ungrouped")-\(firstRow.id)"
    acpAgentID = firstRow.acpAgentID
    agentDisplayName = firstRow.agentDisplayName
    capabilityTags = firstRow.capabilityTags
    rows = [firstRow]
  }

  var showsHeader: Bool {
    acpAgentID != nil
  }

  func canAppend(_ row: ToolCallTimelineRow) -> Bool {
    acpAgentID != nil && acpAgentID == row.acpAgentID
  }
}

struct ToolCallTimelineSectionView: View {
  let section: ToolCallTimelineSection

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      if section.showsHeader,
        let agentDisplayName = section.agentDisplayName
      {
        ToolCallTimelineSectionHeader(
          title: agentDisplayName,
          capabilityTags: section.capabilityTags
        )
      }
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        ForEach(section.rows) { row in
          ToolCallTimelineRowView(row: row)
        }
      }
    }
  }
}

struct ToolCallTimelineSectionHeader: View {
  let title: String
  let capabilityTags: [String]

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text(title)
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      if !capabilityTags.isEmpty {
        HStack(spacing: HarnessMonitorTheme.spacingXS) {
          ForEach(capabilityTags, id: \.self) { tag in
            Text(tag)
              .scaledFont(.caption2.weight(.semibold))
              .foregroundStyle(HarnessMonitorTheme.accent)
              .harnessPillPadding()
              .harnessContentPill(tint: HarnessMonitorTheme.accent.opacity(0.2))
          }
        }
      }
    }
    .padding(.top, HarnessMonitorTheme.spacingXS)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }
}

struct ToolCallTimelineOverflowNoticeView: View {
  let notice: HarnessMonitorStore.ToolCallTimelineOverflowNotice

  var body: some View {
    HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingXS) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(HarnessMonitorTheme.caution)
        .accessibilityHidden(true)
      Text(
        "The latest ACP burst condensed \(notice.rawUpdateCount) raw updates into \(notice.displayedEventCount) displayed tool calls. Older activity is omitted here."
      )
      .scaledFont(.caption)
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
    .padding(HarnessMonitorTheme.spacingSM)
    .background(
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD)
        .fill(HarnessMonitorTheme.caution.opacity(0.12))
    )
    .accessibilityElement(children: .combine)
  }
}

struct ToolCallTimelineRowView: View {
  let row: ToolCallTimelineRow

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.itemSpacing) {
      Image(systemName: row.symbolName)
        .foregroundStyle(row.tint)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(row.title)
          .scaledFont(.subheadline.weight(.semibold))
          .lineLimit(1)
        Text(row.detail)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(2)
      }
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
      VStack(alignment: .trailing, spacing: 2) {
        Text(row.statusDisplayText)
          .scaledFont(.caption2.weight(.semibold))
          .foregroundStyle(row.tint)
        if let stopReasonText = row.formattedStopReason {
          Text(stopReasonText)
            .scaledFont(.caption2)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .multilineTextAlignment(.trailing)
        }
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(row.accessibilityLabel)
    .accessibilityValue(row.accessibilityValue)
    .accessibilityIdentifier(HarnessMonitorAccessibility.toolCallTimelineRow(row.id))
  }
}

struct ToolCallTimelineRow: Identifiable, Equatable {
  let id: String
  let toolCallID: String
  let entryId: String
  let recordedAt: String
  let sequence: UInt64?
  let title: String
  let detail: String
  let status: Status
  let acpAgentID: String?
  let agentDisplayName: String?
  let capabilityTags: [String]
  let stopReason: String?

  enum Status: String, Equatable {
    case started
    case completed
    case failed

    var isTerminal: Bool {
      self != .started
    }
  }

  init?(entry: TimelineEntry) {
    guard let metadata = entry.toolCallTimelineEntryMetadata(),
      let status = Status(rawValue: metadata.status)
    else {
      return nil
    }

    id = metadata.rowID
    toolCallID = metadata.toolCallID
    entryId = entry.entryId
    recordedAt = entry.recordedAt
    sequence = metadata.sequence
    title = metadata.toolName
    detail = entry.summary
    self.status = status
    acpAgentID = metadata.acpAgentID
    agentDisplayName = metadata.agentDisplayName
    capabilityTags = metadata.capabilityTags
    stopReason = metadata.stopReason
  }

  var symbolName: String {
    switch status {
    case .started:
      "clock"
    case .completed:
      "checkmark.circle.fill"
    case .failed:
      "xmark.octagon.fill"
    }
  }

  var tint: Color {
    switch status {
    case .started:
      HarnessMonitorTheme.secondaryInk
    case .completed:
      HarnessMonitorTheme.success
    case .failed:
      HarnessMonitorTheme.danger
    }
  }

  var accessibilityLabel: String {
    detail
  }

  var accessibilityValue: String {
    if let formattedStopReason {
      return "\(statusDisplayText). \(formattedStopReason)"
    }
    return statusDisplayText
  }

  var announcementText: String {
    let actor = agentDisplayName ?? "Agent"
    switch status {
    case .started:
      return "\(actor) started \(title)"
    case .completed:
      return "\(actor) completed \(title)"
    case .failed:
      return "\(actor) failed \(title)"
    }
  }

  var statusDisplayText: String {
    switch status {
    case .started:
      "In progress"
    case .completed:
      "Completed"
    case .failed:
      "Failed"
    }
  }

  var formattedStopReason: String? {
    guard let stopReason, !stopReason.isEmpty else {
      return nil
    }
    switch stopReason {
    case "end_turn":
      return "Ended turn"
    case "error":
      return "Error"
    default:
      return stopReason
        .replacingOccurrences(of: "_", with: " ")
        .localizedCapitalized
    }
  }

  func merging(_ newer: Self) -> Self {
    guard status == newer.status else {
      return newer.status.isTerminal ? newer : self
    }
    return newer.preferredDuplicate(over: self)
  }

  private func preferredDuplicate(over older: Self) -> Self {
    if ToolCallTimelineView.rowSortOrder(lhs: older, rhs: self) {
      return self
    }
    return older
  }
}
