import Foundation
import HarnessKit
import SwiftUI

private func harnessColor(_ name: String) -> Color {
  Color(name, bundle: .main)
}

enum HarnessTheme {
  static var currentStyle: HarnessThemeStyle {
    resolvedStoredStyle()
  }

  static var usesGradientChrome: Bool {
    currentStyle == .gradient
  }

  @ViewBuilder static var canvas: some View {
    if usesGradientChrome {
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

  @ViewBuilder static var sidebarBackground: some View {
    if usesGradientChrome {
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

  @ViewBuilder static var inspectorBackground: some View {
    if usesGradientChrome {
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
  static var accent: Color {
    accent(for: currentStyle)
  }
  static let warmAccent = harnessColor("HarnessWarmAccent")
  static let success = harnessColor("HarnessSuccess")
  static let caution = harnessColor("HarnessCaution")
  static let danger = harnessColor("HarnessDanger")
  static var panel: Color {
    themedColor(gradient: "HarnessPanel", flat: "HarnessFlatPanel")
  }
  static var panelBorder: Color {
    themedColor(gradient: "HarnessPanelBorder", flat: "HarnessFlatPanelBorder")
  }
  static var surface: Color {
    themedColor(gradient: "HarnessSurface", flat: "HarnessFlatSurface")
  }
  static var surfaceHover: Color {
    themedColor(gradient: "HarnessSurfaceHover", flat: "HarnessFlatSurfaceHover")
  }
  static let controlBorder = harnessColor("HarnessControlBorder")
  static var sidebarHeader: Color {
    themedColor(gradient: "HarnessSidebarHeader", flat: "HarnessFlatSidebarHeader")
  }
  static var sidebarMuted: Color {
    themedColor(gradient: "HarnessSidebarMuted", flat: "HarnessFlatSidebarMuted")
  }
  static let overlayScrim = harnessColor("HarnessOverlayScrim")
  static let secondaryInk = ink.opacity(0.78)
  static let tertiaryInk = ink.opacity(0.64)
  static var glassStroke: Color {
    usesGradientChrome ? Color.white.opacity(0.18) : panelBorder.opacity(0.9)
  }
  static var glassHighlight: Color {
    usesGradientChrome ? Color.white.opacity(0.10) : Color.white.opacity(0.03)
  }
  static var glassShadow: Color {
    usesGradientChrome ? Color.black.opacity(0.16) : Color.black.opacity(0.10)
  }

  static func accent(for style: HarnessThemeStyle) -> Color {
    style == .gradient ? harnessColor("HarnessAccent") : harnessColor("HarnessFlatAccent")
  }

  private static func themedColor(gradient: String, flat: String) -> Color {
    currentStyle == .gradient ? harnessColor(gradient) : harnessColor(flat)
  }

  private static func resolvedStoredStyle() -> HarnessThemeStyle {
    HarnessThemeStyle(
      rawValue: UserDefaults.standard.string(forKey: HarnessThemeDefaults.styleKey) ?? ""
    ) ?? .gradient
  }
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

func formatTimestamp(_ date: Date) -> String {
  relativeFormatter.localizedString(for: date, relativeTo: Date())
}

extension ConnectionQuality {
  var themeColor: Color {
    switch self {
    case .excellent, .good:
      HarnessTheme.success
    case .degraded:
      HarnessTheme.caution
    case .poor, .disconnected:
      HarnessTheme.danger
    }
  }
}
