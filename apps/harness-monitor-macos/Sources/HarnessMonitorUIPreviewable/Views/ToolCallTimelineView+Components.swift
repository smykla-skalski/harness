import HarnessMonitorKit
import SwiftUI

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

  var showsHeader: Bool { acpAgentID != nil }
  func canAppend(_ row: ToolCallTimelineRow) -> Bool {
    acpAgentID != nil && acpAgentID == row.acpAgentID
  }
}

struct ToolCallTimelineSectionView: View {
  let section: ToolCallTimelineSection

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      if section.showsHeader, let agentDisplayName = section.agentDisplayName {
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
    .accessibilityLabel(
      ToolCallTimelineView.sectionAccessibilityLabel(
        title: title,
        capabilityTags: capabilityTags
      )
    )
    .accessibilityAddTraits(.isHeader)
  }
}

struct ToolCallTimelineOverflowNoticeView: View {
  let rawUpdateCount: Int
  let visibleToolCallCount: Int

  var body: some View {
    HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingXS) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(HarnessMonitorTheme.caution)
        .accessibilityHidden(true)
      Text(
        ToolCallTimelineView.overflowNoticeText(
          rawUpdateCount: rawUpdateCount,
          visibleToolCallCount: visibleToolCallCount
        )
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
        Text(row.title).scaledFont(.subheadline.weight(.semibold)).lineLimit(1)
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
    var isTerminal: Bool { self != .started }
  }

  init?(entry: TimelineEntry) {
    guard
      let metadata = entry.toolCallTimelineEntryMetadata(),
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
    case .started: "clock"
    case .completed: "checkmark.circle.fill"
    case .failed: "xmark.octagon.fill"
    }
  }

  var tint: Color {
    switch status {
    case .started: HarnessMonitorTheme.secondaryInk
    case .completed: HarnessMonitorTheme.success
    case .failed: HarnessMonitorTheme.danger
    }
  }

  var accessibilityLabel: String { detail }
  var accessibilityValue: String {
    formattedStopReason.map { "\(statusDisplayText). \($0)" } ?? statusDisplayText
  }

  var announcementText: String {
    let actor = agentDisplayName ?? "Agent"
    let suffix = formattedStopReason.map { ". \($0)." } ?? ""
    switch status {
    case .started: return "\(actor) started \(title)\(suffix)"
    case .completed: return "\(actor) completed \(title)\(suffix)"
    case .failed: return "\(actor) failed \(title)\(suffix)"
    }
  }

  var statusDisplayText: String {
    switch status {
    case .started: "In progress"
    case .completed: "Completed"
    case .failed: "Failed"
    }
  }

  var formattedStopReason: String? {
    guard let stopReason, !stopReason.isEmpty else { return nil }
    switch stopReason {
    case "end_turn": return "Ended turn"
    case "error": return "Error"
    default: return stopReason.replacingOccurrences(of: "_", with: " ").localizedCapitalized
    }
  }

  func merging(_ newer: Self) -> Self {
    guard status == newer.status else { return newer.status.isTerminal ? newer : self }
    return newer.preferredDuplicate(over: self)
  }

  private func preferredDuplicate(over older: Self) -> Self {
    ToolCallTimelineView.rowSortOrder(lhs: older, rhs: self) ? self : older
  }
}
