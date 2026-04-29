import AppKit
import HarnessMonitorKit
import SwiftUI

struct ToolCallTimelineView: View {
  let entries: [TimelineEntry]
  let stopSession: () -> Void

  @AppStorage(
    HarnessMonitorToolCallAnnouncementPreferences.verboseAnnouncementsKey
  )
  private var verboseToolCallAnnouncements =
    HarnessMonitorToolCallAnnouncementPreferences.verboseAnnouncementsDefault

  private var presentation: ToolCallTimelinePresentation {
    Self.materialisePresentation(from: entries)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      HStack {
        Text("Tool calls")
          .scaledFont(.headline)
          .accessibilityAddTraits(.isHeader)
        Spacer()
        Button(role: .destructive, action: stopSession) {
          Label("Stop session", systemImage: "stop.fill")
        }
        .harnessActionButtonStyle(variant: .bordered, tint: HarnessMonitorTheme.danger)
      }
      LazyVStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        ForEach(presentation.sections) { section in
          ToolCallTimelineSectionView(section: section)
        }
      }
    }
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.toolCallTimeline)
    .onAppear {
      logDuplicateToolCallIDs(presentation.duplicateToolCallIDs)
    }
    .onChange(of: presentation.duplicateToolCallIDs) { _, duplicateIDs in
      logDuplicateToolCallIDs(duplicateIDs)
    }
    .onChange(of: presentation.announcementStates) { oldValue, _ in
      announceToolCallStateChanges(
        from: oldValue,
        rowsByID: presentation.rowsByID
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
    var duplicateToolCallIDs: [String] = []

    for row in sortedRows {
      guard let existingRow = rowsByID[row.id] else {
        rowsByID[row.id] = row
        continue
      }
      let mergeResult = existingRow.merging(row)
      rowsByID[row.id] = mergeResult.row
      if mergeResult.didDropDuplicate {
        duplicateToolCallIDs.append(row.id)
      }
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
      sections: sections,
      duplicateToolCallIDs: Array(Set(duplicateToolCallIDs)).sorted()
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
    return lhs.entryId < rhs.entryId
  }

  nonisolated static func reverseRowSortOrder(
    lhs: ToolCallTimelineRow,
    rhs: ToolCallTimelineRow
  ) -> Bool {
    if lhs.recordedAt != rhs.recordedAt {
      return lhs.recordedAt > rhs.recordedAt
    }
    return lhs.entryId < rhs.entryId
  }

  private func announceToolCallStateChanges(
    from oldValue: [String: ToolCallTimelineRow.Status],
    rowsByID: [String: ToolCallTimelineRow]
  ) {
    for rowID in rowsByID.keys.sorted() {
      guard
        let row = rowsByID[rowID],
        Self.shouldAnnounceToolCallStatusChange(
          previousStatus: oldValue[rowID],
          row: row,
          verboseAnnouncements: verboseToolCallAnnouncements
        )
      else {
        continue
      }
      AccessibilityNotification.Announcement(row.announcementText).post()
    }
  }

  private func logDuplicateToolCallIDs(_ duplicateIDs: [String]) {
    for duplicateID in duplicateIDs {
      HarnessMonitorLogger.store.warning(
        "Dropping duplicate tool call id \(duplicateID, privacy: .public) from timeline presentation"
      )
    }
  }
}

struct ToolCallTimelinePresentation: Equatable {
  let sections: [ToolCallTimelineSection]
  let duplicateToolCallIDs: [String]

  var rows: [ToolCallTimelineRow] {
    sections.flatMap(\.rows)
  }

  var rowsByID: [String: ToolCallTimelineRow] {
    Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
  }

  var announcementStates: [String: ToolCallTimelineRow.Status] {
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
  }
}

struct ToolCallTimelineRowView: View {
  let row: ToolCallTimelineRow

  var body: some View {
    let content = HStack(spacing: HarnessMonitorTheme.itemSpacing) {
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
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(row.accessibilityLabel)
    .accessibilityValue(row.accessibilityValue)
    .accessibilityIdentifier(HarnessMonitorAccessibility.toolCallTimelineRow(row.id))

    if let liveRegion = row.liveRegion {
      content.accessibilityLiveRegion(liveRegion)
    } else {
      content
    }
  }
}

struct ToolCallTimelineRow: Identifiable, Equatable {
  let id: String
  let entryId: String
  let recordedAt: String
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
    guard let event = Self.toolEventPayload(from: entry) else {
      return nil
    }

    let title = Self.toolName(from: entry, event: event)
    let id = Self.toolCallID(from: entry, event: event)
    let status = Self.status(for: entry, event: event)
    guard let status else {
      return nil
    }

    let payloadMetadata = Self.payloadMetadata(from: entry)
    self.id = id
    entryId = entry.entryId
    recordedAt = entry.recordedAt
    self.title = title
    detail = entry.summary
    self.status = status
    acpAgentID = payloadMetadata?.acpAgentID
    agentDisplayName = payloadMetadata?.agentDisplayName
    capabilityTags = payloadMetadata?.capabilityTags ?? []
    stopReason = payloadMetadata?.stopReason
  }

  var liveRegion: HarnessMonitorAccessibilityLiveRegion? {
    stopReason == nil ? nil : .polite
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
    if let agentDisplayName {
      return "\(agentDisplayName), \(title)"
    }
    return title
  }

  var accessibilityValue: String {
    switch status {
    case .started:
      "In progress"
    case .completed:
      "Completed"
    case .failed:
      "Failed"
    }
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

  func merging(_ newer: Self) -> ToolCallTimelineMergeResult {
    guard status == newer.status else {
      return ToolCallTimelineMergeResult(
        row: newer.status.isTerminal ? newer : self,
        didDropDuplicate: false
      )
    }
    return ToolCallTimelineMergeResult(
      row: newer.preferredDuplicate(over: self),
      didDropDuplicate: true
    )
  }

  private func preferredDuplicate(over older: Self) -> Self {
    if ToolCallTimelineView.rowSortOrder(lhs: older, rhs: self) {
      return self
    }
    return older
  }

  private static func payloadMetadata(from entry: TimelineEntry) -> PayloadMetadata? {
    guard
      case .object(let payload) = entry.payload,
      case .object(let metadata)? = payload["tool_call_timeline"]
    else {
      return nil
    }
    return PayloadMetadata(
      acpAgentID: metadata.stringValue(for: "acp_agent_id"),
      agentDisplayName: metadata.stringValue(for: "agent_display_name"),
      capabilityTags: metadata.arrayStringValues(for: "capability_tags"),
      stopReason: metadata.stringValue(for: "stop_reason")
    )
  }

  private static func toolEventPayload(from entry: TimelineEntry) -> [String: JSONValue]? {
    let canonicalKinds = ["tool_invocation", "tool_result", "tool_result_error"]
    guard canonicalKinds.contains(entry.kind) || entry.kind == "conversation_event",
      case .object(let payload) = entry.payload
    else {
      return nil
    }
    let eventPayload = payload["event"] ?? payload["kind"]
    guard case .object(let event)? = eventPayload else {
      return nil
    }
    return event
  }

  private static func toolName(from entry: TimelineEntry, event: [String: JSONValue]) -> String {
    if case .object(let payload) = entry.payload,
      case .object(let metadata)? = payload["tool_call_timeline"],
      let metadataToolName = metadata.stringValue(for: "tool_name")
    {
      return metadataToolName
    }
    return event.stringValue(for: "tool_name") ?? "Tool"
  }

  private static func toolCallID(from entry: TimelineEntry, event: [String: JSONValue]) -> String {
    if case .object(let payload) = entry.payload,
      case .object(let metadata)? = payload["tool_call_timeline"],
      let metadataToolCallID = metadata.stringValue(for: "tool_call_id")
    {
      return metadataToolCallID
    }
    return event.stringValue(for: "invocation_id") ?? entry.entryId
  }

  private static func status(
    for entry: TimelineEntry,
    event: [String: JSONValue]
  ) -> Status? {
    if case .object(let payload) = entry.payload,
      case .object(let metadata)? = payload["tool_call_timeline"],
      let rawStatus = metadata.stringValue(for: "status")
    {
      return Status(rawValue: rawStatus)
    }

    guard let eventType = event.stringValue(for: "type") else {
      return nil
    }
    switch entry.kind {
    case "tool_invocation":
      return .started
    case "tool_result_error":
      return .failed
    case "tool_result":
      return event.boolValue(for: "is_error") == true ? .failed : .completed
    case "conversation_event":
      switch eventType {
      case "tool_invocation":
        return .started
      case "tool_result":
        return event.boolValue(for: "is_error") == true ? .failed : .completed
      default:
        return nil
      }
    default:
      return nil
    }
  }

  private struct PayloadMetadata: Equatable {
    let acpAgentID: String?
    let agentDisplayName: String?
    let capabilityTags: [String]
    let stopReason: String?
  }
}

struct ToolCallTimelineMergeResult: Equatable {
  let row: ToolCallTimelineRow
  let didDropDuplicate: Bool
}

extension [String: JSONValue] {
  fileprivate func stringValue(for key: String) -> String? {
    guard case .string(let value)? = self[key] else {
      return nil
    }
    return value
  }

  fileprivate func boolValue(for key: String) -> Bool? {
    guard case .bool(let value)? = self[key] else {
      return nil
    }
    return value
  }

  fileprivate func arrayStringValues(for key: String) -> [String] {
    guard case .array(let values)? = self[key] else {
      return []
    }
    return values.compactMap {
      guard case .string(let value) = $0 else {
        return nil
      }
      return value
    }
  }
}
