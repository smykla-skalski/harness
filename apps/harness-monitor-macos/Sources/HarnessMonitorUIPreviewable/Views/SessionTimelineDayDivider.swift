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

  @MainActor private static let timeFormatter = makeFormatter(dateFormat: "HH:mm:ss")
  @MainActor private static let sameYearTimestampFormatter =
    makeFormatter(dateFormat: "d MMM HH:mm:ss")
  @MainActor private static let crossYearTimestampFormatter =
    makeFormatter(dateFormat: "d MMM yyyy HH:mm:ss")
  @MainActor private static let sameYearDayFormatter = makeFormatter(dateFormat: "d MMM")
  @MainActor private static let crossYearDayFormatter = makeFormatter(dateFormat: "d MMM yyyy")

  init(configuration: HarnessMonitorDateTimeConfiguration, now: Date = .now) {
    let timeZone = configuration.effectiveTimeZone
    var calendar = Calendar.autoupdatingCurrent
    calendar.timeZone = timeZone
    self.calendar = calendar
    self.now = now
  }

  func timelineDayStart(for date: Date) -> Date {
    calendar.startOfDay(for: date)
  }

  @MainActor
  func dayDividerLabel(for date: Date) -> String {
    let formatter = dayFormatter(for: date)
    formatter.timeZone = calendar.timeZone
    formatter.calendar = calendar
    return formatter.string(from: date)
  }

  @MainActor
  func timeLabel(for node: SessionTimelineNode) -> String {
    guard isParsedTimestamp(node) else {
      return node.rawTimestamp ?? "n/a"
    }
    let formatter = Self.timeFormatter
    formatter.timeZone = calendar.timeZone
    formatter.calendar = calendar
    return formatter.string(from: node.timestamp)
  }

  @MainActor
  func timestampLabel(for node: SessionTimelineNode) -> String {
    guard isParsedTimestamp(node) else {
      return node.rawTimestamp ?? "n/a"
    }
    let formatter = timestampFormatter(for: node.timestamp)
    formatter.timeZone = calendar.timeZone
    formatter.calendar = calendar
    return formatter.string(from: node.timestamp)
  }

  @MainActor
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

  @MainActor
  private func timestampFormatter(for date: Date) -> DateFormatter {
    calendar.isDate(date, equalTo: now, toGranularity: .year)
      ? Self.sameYearTimestampFormatter
      : Self.crossYearTimestampFormatter
  }

  @MainActor
  private func dayFormatter(for date: Date) -> DateFormatter {
    calendar.isDate(date, equalTo: now, toGranularity: .year)
      ? Self.sameYearDayFormatter
      : Self.crossYearDayFormatter
  }

  @MainActor
  private static func makeFormatter(
    dateFormat: String
  ) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = .autoupdatingCurrent
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
