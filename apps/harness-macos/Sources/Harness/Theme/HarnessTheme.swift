import Foundation
import HarnessKit
import SwiftUI

private func harnessColor(_ name: String) -> Color {
  Color(name, bundle: .main)
}

extension EnvironmentValues {
  @Entry var harnessThemeStyle: HarnessThemeStyle = .gradient
}

enum HarnessTheme {
  static func usesGradientChrome(for style: HarnessThemeStyle) -> Bool {
    style == .gradient
  }

  @ViewBuilder
  static func canvas(for style: HarnessThemeStyle) -> some View {
    if style == .gradient {
      LinearGradient(
        colors: [
          harnessColor("HarnessCanvasStart"),
          harnessColor("HarnessCanvasMiddle"),
          harnessColor("HarnessCanvasEnd"),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    } else {
      harnessColor("HarnessFlatCanvas")
    }
  }

  @ViewBuilder
  static func sidebarBackground(
    for style: HarnessThemeStyle
  ) -> some View {
    if style == .gradient {
      LinearGradient(
        colors: [
          harnessColor("HarnessSidebarStart"),
          harnessColor("HarnessSidebarEnd"),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
    } else {
      harnessColor("HarnessFlatSidebar")
    }
  }

  @ViewBuilder
  static func inspectorBackground(
    for style: HarnessThemeStyle
  ) -> some View {
    if style == .gradient {
      LinearGradient(
        colors: [
          harnessColor("HarnessInspectorStart"),
          harnessColor("HarnessInspectorEnd"),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    } else {
      harnessColor("HarnessFlatInspector")
    }
  }

  static let ink = harnessColor("HarnessInk")
  static let warmAccent = harnessColor("HarnessWarmAccent")
  static let success = harnessColor("HarnessSuccess")
  static let caution = harnessColor("HarnessCaution")
  static let danger = harnessColor("HarnessDanger")
  static let controlBorder = harnessColor("HarnessControlBorder")
  static let overlayScrim = harnessColor("HarnessOverlayScrim")
  static let secondaryInk = ink.opacity(0.78)
  static let tertiaryInk = ink.opacity(0.64)

  static func accent(for style: HarnessThemeStyle) -> Color {
    style == .gradient ? harnessColor("HarnessAccent") : harnessColor("HarnessFlatAccent")
  }

  static func panel(for style: HarnessThemeStyle) -> Color {
    themedColor(gradient: "HarnessPanel", flat: "HarnessFlatPanel", style: style)
  }

  static func panelBorder(for style: HarnessThemeStyle) -> Color {
    themedColor(
      gradient: "HarnessPanelBorder",
      flat: "HarnessFlatPanelBorder",
      style: style
    )
  }

  static func surface(for style: HarnessThemeStyle) -> Color {
    themedColor(gradient: "HarnessSurface", flat: "HarnessFlatSurface", style: style)
  }

  static func surfaceHover(for style: HarnessThemeStyle) -> Color {
    themedColor(
      gradient: "HarnessSurfaceHover",
      flat: "HarnessFlatSurfaceHover",
      style: style
    )
  }

  static func sidebarHeader(for style: HarnessThemeStyle) -> Color {
    themedColor(
      gradient: "HarnessSidebarHeader",
      flat: "HarnessFlatSidebarHeader",
      style: style
    )
  }

  static func sidebarMuted(for style: HarnessThemeStyle) -> Color {
    themedColor(
      gradient: "HarnessSidebarMuted",
      flat: "HarnessFlatSidebarMuted",
      style: style
    )
  }

  static func glassStroke(for style: HarnessThemeStyle) -> Color {
    style == .gradient
      ? Color.white.opacity(0.18)
      : panelBorder(for: style).opacity(0.9)
  }

  static func glassShadow(for style: HarnessThemeStyle) -> Color {
    style == .gradient ? Color.black.opacity(0.16) : Color.black.opacity(0.10)
  }

  private static func themedColor(
    gradient: String,
    flat: String,
    style: HarnessThemeStyle
  ) -> Color {
    style == .gradient ? harnessColor(gradient) : harnessColor(flat)
  }
}

struct HarnessCardModifier: ViewModifier {
  @Environment(\.harnessThemeStyle)
  private var themeStyle
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
          tint: HarnessTheme.panel(for: themeStyle),
          interactive: false,
          fillOpacity: 0.10,
          strokeColor: HarnessTheme.panelBorder(for: themeStyle),
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
        withAnimation(.easeIn(duration: 0.15)) {
          highlight = true
        } completion: {
          withAnimation(.easeOut(duration: 0.75)) {
            highlight = false
          }
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

struct AccessibilityTextMarker: View {
  let identifier: String
  let text: String

  var body: some View {
    Color.clear
      .allowsHitTesting(false)
      .accessibilityElement()
      .accessibilityLabel(text)
      .accessibilityIdentifier(identifier)
  }
}

private struct HarnessSelectionOutlineModifier: ViewModifier {
  let isSelected: Bool
  let cornerRadius: CGFloat
  let lineWidth: CGFloat

  func body(content: Content) -> some View {
    content.overlay {
      if isSelected {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .strokeBorder(.selection, lineWidth: lineWidth)
      }
    }
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
    modifier(AccessibilityFrameMarkerModifier(identifier: identifier))
  }

  func harnessSelectionOutline(
    isSelected: Bool,
    cornerRadius: CGFloat,
    lineWidth: CGFloat = 1.5
  ) -> some View {
    modifier(
      HarnessSelectionOutlineModifier(
        isSelected: isSelected,
        cornerRadius: cornerRadius,
        lineWidth: lineWidth
      )
    )
  }
}

private struct AccessibilityFrameMarkerModifier: ViewModifier {
  private static let isUITesting = ProcessInfo.processInfo.environment["HARNESS_UI_TESTS"] == "1"

  let identifier: String

  @ViewBuilder
  func body(content: Content) -> some View {
    if Self.isUITesting {
      content.overlay {
        AccessibilityFrameMarker(identifier: identifier)
      }
    } else {
      content
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

func severityColor(
  for severity: TaskSeverity,
  style: HarnessThemeStyle
) -> Color {
  switch severity {
  case .low:
    HarnessTheme.accent(for: style).opacity(0.7)
  case .medium:
    HarnessTheme.accent(for: style)
  case .high:
    HarnessTheme.warmAccent
  case .critical:
    HarnessTheme.danger
  }
}

func signalStatusColor(for status: SessionSignalStatus) -> Color {
  switch status {
  case .pending, .deferred:
    HarnessTheme.caution
  case .acknowledged:
    HarnessTheme.success
  case .rejected, .expired:
    HarnessTheme.danger
  }
}

func taskStatusColor(
  for status: TaskStatus,
  style: HarnessThemeStyle
) -> Color {
  switch status {
  case .open:
    HarnessTheme.accent(for: style)
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

  return relativeFormatter.localizedString(for: date, relativeTo: .now)
}

func formatTimestamp(_ date: Date) -> String {
  relativeFormatter.localizedString(for: date, relativeTo: .now)
}
