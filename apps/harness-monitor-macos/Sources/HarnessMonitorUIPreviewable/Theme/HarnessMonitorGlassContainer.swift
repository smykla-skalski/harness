import SwiftUI

enum HarnessMonitorFloatingGlassProminence {
  case subdued
  case regular
}

private struct HarnessGlassContainerActiveKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  var harnessGlassContainerActive: Bool {
    get { self[HarnessGlassContainerActiveKey.self] }
    set { self[HarnessGlassContainerActiveKey.self] = newValue }
  }
}

extension View {
  func harnessGlassContainerScope() -> some View {
    modifier(HarnessGlassContainerScopeModifier())
  }
}

private struct HarnessGlassContainerScopeModifier: ViewModifier {
  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency

  func body(content: Content) -> some View {
    if reduceTransparency {
      content
    } else {
      GlassEffectContainer {
        content
          .environment(\.harnessGlassContainerActive, true)
      }
    }
  }
}

struct HarnessMonitorGlassControlGroup<Content: View>: View {
  let spacing: CGFloat?
  private let content: Content
  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency
  @Environment(\.harnessGlassContainerActive)
  private var containerActive

  init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
    self.spacing = spacing
    self.content = content()
  }

  var body: some View {
    if reduceTransparency || containerActive {
      content
    } else if let spacing {
      GlassEffectContainer(spacing: spacing) {
        content
      }
    } else {
      GlassEffectContainer {
        content
      }
    }
  }
}
