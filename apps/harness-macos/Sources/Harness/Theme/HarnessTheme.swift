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
