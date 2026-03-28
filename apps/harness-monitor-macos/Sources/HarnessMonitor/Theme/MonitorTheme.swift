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

  static let ink = Color(red: 0.12, green: 0.15, blue: 0.19)
  static let accent = Color(red: 0.14, green: 0.43, blue: 0.60)
  static let warmAccent = Color(red: 0.78, green: 0.38, blue: 0.16)
  static let success = Color(red: 0.22, green: 0.54, blue: 0.31)
  static let caution = Color(red: 0.74, green: 0.47, blue: 0.14)
  static let danger = Color(red: 0.73, green: 0.21, blue: 0.22)
  static let panel = Color.white.opacity(0.72)
  static let panelBorder = Color.white.opacity(0.55)
}

struct MonitorCardModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .padding(18)
      .background(
        RoundedRectangle(cornerRadius: 24, style: .continuous)
          .fill(MonitorTheme.panel)
          .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
              .stroke(MonitorTheme.panelBorder, lineWidth: 1)
          )
          .shadow(color: .black.opacity(0.08), radius: 14, x: 0, y: 10)
      )
  }
}

extension View {
  func monitorCard() -> some View {
    modifier(MonitorCardModifier())
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

func formatTimestamp(_ value: String?) -> String {
  guard let value, let date = ISO8601DateFormatter().date(from: value) else {
    return value ?? "n/a"
  }

  let formatter = RelativeDateTimeFormatter()
  formatter.unitsStyle = .short
  return formatter.localizedString(for: date, relativeTo: Date())
}
