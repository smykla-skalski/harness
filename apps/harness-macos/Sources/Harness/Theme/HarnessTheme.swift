import HarnessKit
import SwiftUI

private func harnessColor(_ name: String) -> Color {
  Color(name, bundle: .main)
}

enum HarnessTheme {
  static let canvas = LinearGradient(
    colors: [
      harnessColor("HarnessCanvasStart"),
      harnessColor("HarnessCanvasMiddle"),
      harnessColor("HarnessCanvasEnd"),
    ],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
  )
  static let sidebarBackground = LinearGradient(
    colors: [
      harnessColor("HarnessSidebarStart"),
      harnessColor("HarnessSidebarEnd"),
    ],
    startPoint: .top,
    endPoint: .bottom
  )
  static let inspectorBackground = LinearGradient(
    colors: [
      harnessColor("HarnessInspectorStart"),
      harnessColor("HarnessInspectorEnd"),
    ],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
  )

  static let ink = harnessColor("HarnessInk")
  static let accent = harnessColor("HarnessAccent")
  static let warmAccent = harnessColor("HarnessWarmAccent")
  static let success = harnessColor("HarnessSuccess")
  static let caution = harnessColor("HarnessCaution")
  static let danger = harnessColor("HarnessDanger")
  static let panel = harnessColor("HarnessPanel")
  static let panelBorder = harnessColor("HarnessPanelBorder")
  static let surface = harnessColor("HarnessSurface")
  static let surfaceHover = harnessColor("HarnessSurfaceHover")
  static let controlBorder = harnessColor("HarnessControlBorder")
  static let sidebarHeader = harnessColor("HarnessSidebarHeader")
  static let sidebarMuted = harnessColor("HarnessSidebarMuted")
  static let overlayScrim = harnessColor("HarnessOverlayScrim")
  static let secondaryInk = ink.opacity(0.78)
  static let tertiaryInk = ink.opacity(0.64)
  static let glassStroke = Color.white.opacity(0.18)
  static let glassHighlight = Color.white.opacity(0.10)
  static let glassShadow = Color.black.opacity(0.16)
}

struct HarnessCardModifier: ViewModifier {
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
        HarnessRoundedGlassBackground(
          cornerRadius: 22,
          tint: HarnessTheme.panel,
          interactive: false,
          fillOpacity: 0.10,
          strokeColor: HarnessTheme.panelBorder,
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
            HarnessTheme.success.opacity(highlight ? 0.18 : 0),
            lineWidth: 1
          )
      )
      .shadow(
        color: HarnessTheme.success.opacity(highlight ? 0.08 : 0),
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

struct HarnessLoadingStateView: View {
  let title: String
  @State private var animates = false

  var body: some View {
    HStack(spacing: 10) {
      HarnessSpinner(size: 14)
      Text(title)
        .font(.system(.footnote, design: .rounded, weight: .semibold))
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background {
      HarnessGlassCapsuleBackground()
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
  func harnessCard(
    minHeight: CGFloat? = nil,
    contentPadding: CGFloat = 16
  ) -> some View {
    modifier(HarnessCardModifier(minHeight: minHeight, contentPadding: contentPadding))
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

func harnessActionHeader(title: String, subtitle: String) -> some View {
  VStack(alignment: .leading, spacing: 4) {
    Text(title)
      .font(.system(.headline, design: .rounded, weight: .semibold))
    Text(subtitle)
      .font(.system(.subheadline, design: .rounded, weight: .medium))
      .foregroundStyle(HarnessTheme.secondaryInk)
  }
}

func harnessBadge(_ value: String) -> some View {
  Text(value)
    .font(.caption.bold())
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background {
      HarnessGlassCapsuleBackground()
    }
}

func statusColor(for status: SessionStatus) -> Color {
  switch status {
  case .active:
    HarnessTheme.success
  case .paused:
    HarnessTheme.caution
  case .ended:
    HarnessTheme.ink.opacity(0.55)
  }
}

func severityColor(for severity: TaskSeverity) -> Color {
  switch severity {
  case .low:
    HarnessTheme.accent.opacity(0.7)
  case .medium:
    HarnessTheme.accent
  case .high:
    HarnessTheme.warmAccent
  case .critical:
    HarnessTheme.danger
  }
}

func taskStatusColor(for status: TaskStatus) -> Color {
  switch status {
  case .open:
    HarnessTheme.accent
  case .inProgress:
    HarnessTheme.warmAccent
  case .inReview:
    HarnessTheme.caution
  case .done:
    HarnessTheme.success
  case .blocked:
    HarnessTheme.danger
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
