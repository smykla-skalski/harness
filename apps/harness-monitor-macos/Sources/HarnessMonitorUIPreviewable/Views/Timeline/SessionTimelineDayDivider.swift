import Foundation
import SwiftUI

struct SessionTimelineRow: Identifiable, Equatable {
  let node: SessionTimelineNode
  let dayDividerLabel: String?
  let timestampLabel: String
  let accessibilityTimestampLabel: String
  let accessibilityLabel: String

  var id: String { node.id }

  @MainActor
  static func rows(
    for nodes: [SessionTimelineNode],
    configuration: HarnessMonitorDateTimeConfiguration
  ) -> [Self] {
    var previousDay: Date?
    return nodes.map { node in
      let day = timelineDayStart(for: node.timestamp, configuration: configuration)
      let label =
        previousDay != nil && previousDay != day
        ? formatTimelineDayDivider(node.timestamp, configuration: configuration)
        : nil
      previousDay = day
      return Self(
        node: node,
        dayDividerLabel: label,
        timestampLabel: resolvedTimeLabel(for: node, configuration: configuration),
        accessibilityTimestampLabel: resolvedTimestampLabel(
          for: node,
          configuration: configuration
        ),
        accessibilityLabel: resolvedAccessibilityLabel(
          for: node,
          configuration: configuration
        )
      )
    }
  }

  @MainActor
  private static func resolvedTimeLabel(
    for node: SessionTimelineNode,
    configuration: HarnessMonitorDateTimeConfiguration
  ) -> String {
    guard isParsedTimestamp(node) else {
      return node.rawTimestamp ?? "n/a"
    }
    return formatTimelineTime(node.timestamp, configuration: configuration)
  }

  @MainActor
  private static func resolvedTimestampLabel(
    for node: SessionTimelineNode,
    configuration: HarnessMonitorDateTimeConfiguration
  ) -> String {
    guard isParsedTimestamp(node) else {
      return node.rawTimestamp ?? "n/a"
    }
    return formatTimelineTimestamp(node.timestamp, configuration: configuration)
  }

  @MainActor
  private static func resolvedAccessibilityLabel(
    for node: SessionTimelineNode,
    configuration: HarnessMonitorDateTimeConfiguration
  ) -> String {
    if let override = node.voiceOverLabelOverride {
      return override
    }
    var parts = [
      node.kind.label,
      resolvedTimestampLabel(for: node, configuration: configuration),
      "Source \(node.sourceLabel)",
    ]
    if let eventTone = node.eventTone {
      parts.append("Tone \(eventTone.label)")
    }
    if let decision = node.decision {
      parts.append("Severity \(decision.severityLabel)")
    }
    parts.append(node.title)
    if let detail = node.detail {
      parts.append(detail)
    }
    parts.append(node.actionAvailabilityLabel)
    return parts.joined(separator: ", ")
  }

  private static func isParsedTimestamp(_ node: SessionTimelineNode) -> Bool {
    node.rawTimestamp == nil || node.timestamp != .distantPast
  }
}

struct SessionTimelineDayDivider: View {
  let label: String

  var body: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.itemSpacing) {
      Color.clear
        .frame(width: SessionTimelineLayout.timeColumnWidth)
      Color.clear
        .frame(width: SessionTimelineLayout.railWidth)
      divider
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, HarnessMonitorTheme.spacingXS)
    .accessibilityLabel("Timeline date \(label)")
  }

  private var divider: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      line
      Text(label)
        .scaledFont(.caption.monospaced().weight(.medium))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
      line
    }
    .frame(maxWidth: .infinity, alignment: .center)
  }

  private var line: some View {
    Rectangle()
      .fill(HarnessMonitorTheme.controlBorder.opacity(0.42))
      .frame(height: 1)
  }
}
