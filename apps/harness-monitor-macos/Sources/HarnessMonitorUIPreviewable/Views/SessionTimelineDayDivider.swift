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
    let formatter = SessionTimelineRowFormatter(configuration: configuration)
    var previousDay: Date?
    return nodes.map { node in
      let day = formatter.timelineDayStart(for: node.timestamp)
      let label =
        previousDay != nil && previousDay != day
        ? formatter.dayDividerLabel(for: node.timestamp)
        : nil
      previousDay = day
      return Self(
        node: node,
        dayDividerLabel: label,
        timestampLabel: formatter.timeLabel(for: node),
        accessibilityTimestampLabel: formatter.timestampLabel(for: node),
        accessibilityLabel: formatter.accessibilityLabel(for: node)
      )
    }
  }
}

private final class SessionTimelineRowFormatter {
  private let calendar: Calendar
  private let now: Date
  private let timeFormatter: DateFormatter
  private let sameYearTimestampFormatter: DateFormatter
  private let crossYearTimestampFormatter: DateFormatter
  private let sameYearDayFormatter: DateFormatter
  private let crossYearDayFormatter: DateFormatter

  init(configuration: HarnessMonitorDateTimeConfiguration, now: Date = .now) {
    let timeZone = configuration.effectiveTimeZone
    var calendar = Calendar.autoupdatingCurrent
    calendar.timeZone = timeZone
    self.calendar = calendar
    self.now = now
    timeFormatter = Self.makeFormatter(
      dateFormat: "HH:mm:ss", timeZone: timeZone, calendar: calendar)
    sameYearTimestampFormatter = Self.makeFormatter(
      dateFormat: "d MMM HH:mm:ss", timeZone: timeZone, calendar: calendar)
    crossYearTimestampFormatter = Self.makeFormatter(
      dateFormat: "d MMM yyyy HH:mm:ss", timeZone: timeZone, calendar: calendar)
    sameYearDayFormatter = Self.makeFormatter(
      dateFormat: "d MMM", timeZone: timeZone, calendar: calendar)
    crossYearDayFormatter = Self.makeFormatter(
      dateFormat: "d MMM yyyy", timeZone: timeZone, calendar: calendar)
  }

  func timelineDayStart(for date: Date) -> Date {
    calendar.startOfDay(for: date)
  }

  func dayDividerLabel(for date: Date) -> String {
    dayFormatter(for: date).string(from: date)
  }

  func timeLabel(for node: SessionTimelineNode) -> String {
    guard isParsedTimestamp(node) else {
      return node.rawTimestamp ?? "n/a"
    }
    return timeFormatter.string(from: node.timestamp)
  }

  func timestampLabel(for node: SessionTimelineNode) -> String {
    guard isParsedTimestamp(node) else {
      return node.rawTimestamp ?? "n/a"
    }
    return timestampFormatter(for: node.timestamp).string(from: node.timestamp)
  }

  func accessibilityLabel(for node: SessionTimelineNode) -> String {
    var parts = [
      node.kind.label,
      timestampLabel(for: node),
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

  private func isParsedTimestamp(_ node: SessionTimelineNode) -> Bool {
    node.rawTimestamp == nil || node.timestamp != .distantPast
  }

  private func timestampFormatter(for date: Date) -> DateFormatter {
    calendar.isDate(date, equalTo: now, toGranularity: .year)
      ? sameYearTimestampFormatter
      : crossYearTimestampFormatter
  }

  private func dayFormatter(for date: Date) -> DateFormatter {
    calendar.isDate(date, equalTo: now, toGranularity: .year)
      ? sameYearDayFormatter
      : crossYearDayFormatter
  }

  private static func makeFormatter(
    dateFormat: String, timeZone: TimeZone, calendar: Calendar
  ) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.dateFormat = dateFormat
    formatter.timeZone = timeZone
    formatter.calendar = calendar
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
