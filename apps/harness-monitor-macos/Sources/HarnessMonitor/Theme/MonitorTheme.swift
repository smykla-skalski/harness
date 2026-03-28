import AppKit
import HarnessMonitorKit
import SwiftUI

private func adaptive(light: NSColor, dark: NSColor) -> Color {
  let resolved = NSColor(
    name: nil,
    dynamicProvider: { appearance in
      let isDark =
        appearance.bestMatch(
          from: [.darkAqua, .accessibilityHighContrastDarkAqua]
        ) != nil
      return isDark ? dark : light
    })
  return Color(nsColor: resolved)
}

private func adaptiveGradient(
  lightColors: [NSColor],
  darkColors: [NSColor],
  startPoint: UnitPoint,
  endPoint: UnitPoint
) -> LinearGradient {
  LinearGradient(
    colors: zip(lightColors, darkColors).map { light, dark in
      adaptive(light: light, dark: dark)
    },
    startPoint: startPoint,
    endPoint: endPoint
  )
}

enum MonitorTheme {
  static let canvas = adaptiveGradient(
    lightColors: [
      NSColor(red: 0.97, green: 0.95, blue: 0.90, alpha: 1),
      NSColor(red: 0.88, green: 0.92, blue: 0.96, alpha: 1),
      NSColor(red: 0.96, green: 0.88, blue: 0.79, alpha: 1),
    ],
    darkColors: [
      NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1),
      NSColor(red: 0.12, green: 0.13, blue: 0.16, alpha: 1),
      NSColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 1),
    ],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
  )
  static let sidebarBackground = adaptiveGradient(
    lightColors: [
      NSColor(red: 0.28, green: 0.28, blue: 0.26, alpha: 1),
      NSColor(red: 0.34, green: 0.35, blue: 0.37, alpha: 1),
    ],
    darkColors: [
      NSColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1),
      NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1),
    ],
    startPoint: .top,
    endPoint: .bottom
  )
  static let inspectorBackground = adaptiveGradient(
    lightColors: [
      NSColor(red: 0.98, green: 0.97, blue: 0.95, alpha: 1),
      NSColor(red: 0.95, green: 0.93, blue: 0.89, alpha: 1),
    ],
    darkColors: [
      NSColor(red: 0.13, green: 0.13, blue: 0.15, alpha: 1),
      NSColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 1),
    ],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
  )

  static let ink = adaptive(
    light: NSColor(red: 0.12, green: 0.15, blue: 0.19, alpha: 1),
    dark: NSColor(red: 0.90, green: 0.91, blue: 0.93, alpha: 1)
  )
  static let accent = adaptive(
    light: NSColor(red: 0.14, green: 0.43, blue: 0.60, alpha: 1),
    dark: NSColor(red: 0.35, green: 0.62, blue: 0.82, alpha: 1)
  )
  static let warmAccent = adaptive(
    light: NSColor(red: 0.78, green: 0.38, blue: 0.16, alpha: 1),
    dark: NSColor(red: 0.90, green: 0.55, blue: 0.30, alpha: 1)
  )
  static let success = adaptive(
    light: NSColor(red: 0.22, green: 0.54, blue: 0.31, alpha: 1),
    dark: NSColor(red: 0.35, green: 0.72, blue: 0.45, alpha: 1)
  )
  static let caution = adaptive(
    light: NSColor(red: 0.74, green: 0.47, blue: 0.14, alpha: 1),
    dark: NSColor(red: 0.88, green: 0.62, blue: 0.28, alpha: 1)
  )
  static let danger = adaptive(
    light: NSColor(red: 0.73, green: 0.21, blue: 0.22, alpha: 1),
    dark: NSColor(red: 0.90, green: 0.38, blue: 0.38, alpha: 1)
  )
  static let panel = adaptive(
    light: NSColor(white: 1.0, alpha: 0.82),
    dark: NSColor(white: 1.0, alpha: 0.08)
  )
  static let panelBorder = adaptive(
    light: NSColor(white: 1.0, alpha: 0.78),
    dark: NSColor(white: 1.0, alpha: 0.12)
  )
  static let sidebarHeader = adaptive(
    light: NSColor(red: 0.97, green: 0.97, blue: 0.95, alpha: 1),
    dark: NSColor(red: 0.94, green: 0.95, blue: 0.97, alpha: 1)
  )
  static let sidebarMuted = adaptive(
    light: NSColor(red: 0.82, green: 0.84, blue: 0.87, alpha: 1),
    dark: NSColor(red: 0.70, green: 0.72, blue: 0.76, alpha: 1)
  )
  static let overlayScrim = adaptive(
    light: NSColor(white: 0.04, alpha: 0.18),
    dark: NSColor(white: 0.0, alpha: 0.34)
  )
}

struct MonitorCardModifier: ViewModifier {
  let minHeight: CGFloat?

  func body(content: Content) -> some View {
    content
      .frame(
        maxWidth: .infinity,
        minHeight: minHeight,
        alignment: .topLeading
      )
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

func monitorActionHeader(title: String, subtitle: String) -> some View {
  VStack(alignment: .leading, spacing: 4) {
    Text(title)
      .font(.system(.headline, design: .rounded, weight: .semibold))
    Text(subtitle)
      .font(.system(.subheadline, design: .rounded, weight: .medium))
      .foregroundStyle(.secondary)
  }
}

func monitorBadge(_ value: String) -> some View {
  Text(value)
    .font(.caption.bold())
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(MonitorTheme.panel, in: Capsule())
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
