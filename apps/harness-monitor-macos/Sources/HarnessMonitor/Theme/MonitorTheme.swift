import HarnessMonitorKit
import SwiftUI

private func monitorColor(_ name: String) -> Color {
  Color(name, bundle: .main)
}

enum MonitorTheme {
  static let canvas = LinearGradient(
    colors: [
      monitorColor("MonitorCanvasStart"),
      monitorColor("MonitorCanvasMiddle"),
      monitorColor("MonitorCanvasEnd"),
    ],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
  )
  static let sidebarBackground = LinearGradient(
    colors: [
      monitorColor("MonitorSidebarStart"),
      monitorColor("MonitorSidebarEnd"),
    ],
    startPoint: .top,
    endPoint: .bottom
  )
  static let inspectorBackground = LinearGradient(
    colors: [
      monitorColor("MonitorInspectorStart"),
      monitorColor("MonitorInspectorEnd"),
    ],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
  )

  static let ink = monitorColor("MonitorInk")
  static let accent = monitorColor("MonitorAccent")
  static let warmAccent = monitorColor("MonitorWarmAccent")
  static let success = monitorColor("MonitorSuccess")
  static let caution = monitorColor("MonitorCaution")
  static let danger = monitorColor("MonitorDanger")
  static let panel = monitorColor("MonitorPanel")
  static let panelBorder = monitorColor("MonitorPanelBorder")
  static let surface = monitorColor("MonitorSurface")
  static let surfaceHover = monitorColor("MonitorSurfaceHover")
  static let controlBorder = monitorColor("MonitorControlBorder")
  static let sidebarHeader = monitorColor("MonitorSidebarHeader")
  static let sidebarMuted = monitorColor("MonitorSidebarMuted")
  static let overlayScrim = monitorColor("MonitorOverlayScrim")
  static let glassStroke = Color.white.opacity(0.18)
  static let glassHighlight = Color.white.opacity(0.10)
  static let glassShadow = Color.black.opacity(0.16)
}

struct MonitorCardModifier: ViewModifier {
  let minHeight: CGFloat?
  let contentPadding: CGFloat

  func body(content: Content) -> some View {
    content
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(contentPadding)
      .frame(
        maxWidth: .infinity,
        minHeight: minHeight,
        alignment: .topLeading
      )
      .background {
        MonitorRoundedGlassBackground(
          cornerRadius: 22,
          tint: nil,
          interactive: false,
          fallbackMaterial: .regularMaterial,
          fallbackOverlay: MonitorTheme.panel.opacity(0.18),
          strokeColor: MonitorTheme.panelBorder,
          shadowColor: .black.opacity(0.07),
          shadowRadius: 12,
          shadowY: 8
        )
      }
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct LiveActivityBorderModifier: ViewModifier {
  let isActive: Bool
  @State private var highlight = false

  func body(content: Content) -> some View {
    content
      .overlay(
        RoundedRectangle(cornerRadius: 22, style: .continuous)
          .stroke(
            MonitorTheme.success.opacity(highlight ? 0.18 : 0),
            lineWidth: 1
          )
      )
      .shadow(
        color: MonitorTheme.success.opacity(highlight ? 0.08 : 0),
        radius: highlight ? 12 : 0,
        x: 0,
        y: 0
      )
      .onChange(of: isActive) { _, active in
        guard active else { return }
        withAnimation(.easeIn(duration: 0.15)) { highlight = true }
        withAnimation(.easeOut(duration: 0.75).delay(0.15)) {
          highlight = false
        }
      }
  }
}

struct MonitorLoadingStateView: View {
  let title: String
  @State private var animates = false

  var body: some View {
    HStack(spacing: 10) {
      MonitorSpinner(size: 14)
      Text(title)
        .font(.system(.footnote, design: .rounded, weight: .semibold))
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background {
      MonitorGlassCapsuleBackground()
    }
    .opacity(animates ? 1 : 0.82)
    .scaleEffect(animates ? 1 : 0.985)
    .animation(
      .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
      value: animates
    )
    .onAppear {
      animates = true
    }
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
  func monitorCard(
    minHeight: CGFloat? = nil,
    contentPadding: CGFloat = 16
  ) -> some View {
    modifier(MonitorCardModifier(minHeight: minHeight, contentPadding: contentPadding))
  }

  func liveActivityBorder(isActive: Bool) -> some View {
    modifier(LiveActivityBorderModifier(isActive: isActive))
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
    .background {
      MonitorGlassCapsuleBackground()
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
