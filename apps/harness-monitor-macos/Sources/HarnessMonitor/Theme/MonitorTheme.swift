import HarnessMonitorKit
import SwiftUI

enum MonitorTheme {
  static let canvas = LinearGradient(
    colors: [
      Color(red: 0.97, green: 0.95, blue: 0.90),
      Color(red: 0.88, green: 0.92, blue: 0.96),
      Color(red: 0.96, green: 0.88, blue: 0.79),
    ],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
  )
  static let sidebarBackground = LinearGradient(
    colors: [
      Color(red: 0.28, green: 0.28, blue: 0.26),
      Color(red: 0.34, green: 0.35, blue: 0.37),
    ],
    startPoint: .top,
    endPoint: .bottom
  )
  static let inspectorBackground = LinearGradient(
    colors: [
      Color(red: 0.98, green: 0.97, blue: 0.95),
      Color(red: 0.95, green: 0.93, blue: 0.89),
    ],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
  )

  static let ink = Color(red: 0.12, green: 0.15, blue: 0.19)
  static let accent = Color(red: 0.14, green: 0.43, blue: 0.60)
  static let warmAccent = Color(red: 0.78, green: 0.38, blue: 0.16)
  static let success = Color(red: 0.22, green: 0.54, blue: 0.31)
  static let caution = Color(red: 0.74, green: 0.47, blue: 0.14)
  static let danger = Color(red: 0.73, green: 0.21, blue: 0.22)
  static let panel = Color.white.opacity(0.82)
  static let panelBorder = Color.white.opacity(0.78)
}

struct MonitorCardModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 24, style: .continuous)
          .fill(MonitorTheme.panel)
          .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
              .stroke(MonitorTheme.panelBorder, lineWidth: 1)
          )
          .shadow(color: .black.opacity(0.08), radius: 14, x: 0, y: 10)
      )
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct AccessibilityFrameMarker: View {
  let identifier: String

  var body: some View {
    Color.clear
      .allowsHitTesting(false)
      .accessibilityElement()
      .accessibilityIdentifier(identifier)
  }
}

extension View {
  func monitorCard() -> some View {
    modifier(MonitorCardModifier())
  }

  func accessibilityFrameMarker(_ identifier: String) -> some View {
    overlay {
      AccessibilityFrameMarker(identifier: identifier)
    }
  }
}

func statusColor(for status: SessionStatus) -> Color {
  switch status {
  case .active:
    MonitorTheme.success
  case .paused:
    MonitorTheme.caution
  case .ended:
    MonitorTheme.ink.opacity(0.55)
  }
}

func severityColor(for severity: TaskSeverity) -> Color {
  switch severity {
  case .low:
    MonitorTheme.accent.opacity(0.7)
  case .medium:
    MonitorTheme.accent
  case .high:
    MonitorTheme.warmAccent
  case .critical:
    MonitorTheme.danger
  }
}

func taskStatusColor(for status: TaskStatus) -> Color {
  switch status {
  case .open:
    MonitorTheme.accent
  case .inProgress:
    MonitorTheme.warmAccent
  case .inReview:
    MonitorTheme.caution
  case .done:
    MonitorTheme.success
  case .blocked:
    MonitorTheme.danger
  }
}

nonisolated(unsafe) private let iso8601Formatter: ISO8601DateFormatter = {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter
}()

nonisolated(unsafe) private let relativeFormatter: RelativeDateTimeFormatter = {
  let formatter = RelativeDateTimeFormatter()
  formatter.unitsStyle = .short
  return formatter
}()

func formatTimestamp(_ value: String?) -> String {
  guard let value, let date = iso8601Formatter.date(from: value) else {
    return value ?? "n/a"
  }

  return relativeFormatter.localizedString(for: date, relativeTo: Date())
}
