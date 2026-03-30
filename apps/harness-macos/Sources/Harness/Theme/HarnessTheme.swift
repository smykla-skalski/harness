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
    ZStack(alignment: .topLeading) {
      content
        .environment(\.isInsideGlassEffect, true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(contentPadding)
    }
    .frame(
      maxWidth: .infinity,
      minHeight: minHeight,
      alignment: .topLeading
    )
    .background {
      cardBackground
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder private var cardBackground: some View {
    let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
    let panelColor = HarnessTheme.panel(for: themeStyle)
    let borderColor = HarnessTheme.panelBorder(for: themeStyle)

    if HarnessTheme.usesGradientChrome(for: themeStyle) {
      shape
        .fill(panelColor.opacity(0.22))
        .overlay {
          shape.stroke(borderColor.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.07), radius: 12, x: 0, y: 8)
    } else {
      shape
        .fill(panelColor.opacity(0.10))
        .overlay {
          shape.stroke(borderColor, lineWidth: 1)
        }
        .shadow(
          color: .black.opacity(0.05),
          radius: 4,
          x: 0,
          y: 2
        )
    }
  }
}

struct LiveActivityBorderModifier: ViewModifier {
  let isActive: Bool
  @State private var highlight = false
  @State private var flashTrigger = 0

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
        flashTrigger += 1
      }
      .onChange(of: flashTrigger) {
        highlight = false
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
    .opacity(animates ? 1 : 0.62)
    .scaleEffect(animates ? 1 : 0.97)
    .animation(
      .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
      value: animates
    )
    .onAppear { animates = true }
    .onDisappear { animates = false }
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
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .strokeBorder(.selection, lineWidth: lineWidth)
        .opacity(isSelected ? 1 : 0)
    }
    .animation(.spring(duration: 0.2), value: isSelected)
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
