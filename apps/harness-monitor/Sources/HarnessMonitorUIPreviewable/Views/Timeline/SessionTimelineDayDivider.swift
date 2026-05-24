import Foundation
import SwiftUI

struct SessionTimelineRow: Identifiable, Equatable, Sendable {
  let node: SessionTimelineNode
  let dayDividerLabel: String?
  let timestampLabel: String
  let accessibilityTimestampLabel: String
  let accessibilityLabel: String

  var id: String { node.id }

  static func rows(
    for nodes: [SessionTimelineNode],
    configuration: HarnessMonitorDateTimeConfiguration
  ) -> [Self] {
    var previousDay: Date?
    let formatter = SessionTimelineRowDateFormatter(configuration: configuration)
    return nodes.map { node in
      let day = formatter.dayStart(for: node.timestamp)
      let label =
        previousDay != nil && previousDay != day
        ? formatter.dayDividerLabel(for: node.timestamp)
        : nil
      previousDay = day
      return Self(
        node: node,
        dayDividerLabel: label,
        timestampLabel: resolvedTimeLabel(for: node, formatter: formatter),
        accessibilityTimestampLabel: resolvedTimestampLabel(
          for: node,
          formatter: formatter
        ),
        accessibilityLabel: resolvedAccessibilityLabel(
          for: node,
          formatter: formatter
        )
      )
    }
  }

  private static func resolvedTimeLabel(
    for node: SessionTimelineNode,
    formatter: SessionTimelineRowDateFormatter
  ) -> String {
    guard isParsedTimestamp(node) else {
      return node.rawTimestamp ?? "n/a"
    }
    return formatter.timeLabel(for: node.timestamp)
  }

  private static func resolvedTimestampLabel(
    for node: SessionTimelineNode,
    formatter: SessionTimelineRowDateFormatter
  ) -> String {
    guard isParsedTimestamp(node) else {
      return node.rawTimestamp ?? "n/a"
    }
    return formatter.timestampLabel(for: node.timestamp)
  }

  private static func resolvedAccessibilityLabel(
    for node: SessionTimelineNode,
    formatter: SessionTimelineRowDateFormatter
  ) -> String {
    if let override = node.voiceOverLabelOverride {
      return override
    }
    var parts = [
      node.kind.label,
      resolvedTimestampLabel(for: node, formatter: formatter),
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

private struct SessionTimelineRowDateFormatter {
  private let calendar: Calendar
  private let timeFormatter: DateFormatter
  private let sameYearTimestampFormatter: DateFormatter
  private let crossYearTimestampFormatter: DateFormatter
  private let sameYearDayDividerFormatter: DateFormatter
  private let crossYearDayDividerFormatter: DateFormatter

  init(configuration: HarnessMonitorDateTimeConfiguration) {
    var calendar = Calendar.autoupdatingCurrent
    calendar.timeZone = configuration.effectiveTimeZone
    self.calendar = calendar
    timeFormatter = Self.formatter(dateFormat: "HH:mm:ss", calendar: calendar)
    sameYearTimestampFormatter = Self.formatter(dateFormat: "MMM HH:mm:ss", calendar: calendar)
    crossYearTimestampFormatter = Self.formatter(
      dateFormat: "MMM yyyy HH:mm:ss",
      calendar: calendar
    )
    sameYearDayDividerFormatter = Self.formatter(dateFormat: "d MMM", calendar: calendar)
    crossYearDayDividerFormatter = Self.formatter(dateFormat: "d MMM yyyy", calendar: calendar)
  }

  func dayStart(for date: Date) -> Date {
    calendar.startOfDay(for: date)
  }

  func timeLabel(for date: Date) -> String {
    timeFormatter.string(from: date)
  }

  func timestampLabel(for date: Date) -> String {
    let formatter = isSameYear(date) ? sameYearTimestampFormatter : crossYearTimestampFormatter
    let day = calendar.component(.day, from: date)
    return String(format: "%2d %@", day, formatter.string(from: date))
  }

  func dayDividerLabel(for date: Date) -> String {
    let formatter =
      isSameYear(date) ? sameYearDayDividerFormatter : crossYearDayDividerFormatter
    return formatter.string(from: date)
  }

  private func isSameYear(_ date: Date) -> Bool {
    calendar.isDate(date, equalTo: .now, toGranularity: .year)
  }

  private static func formatter(dateFormat: String, calendar: Calendar) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = dateFormat
    return formatter
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
