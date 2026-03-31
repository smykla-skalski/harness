import SwiftUI

struct HarnessGlassContainer<Content: View>: View {
  let spacing: CGFloat?
  private let content: Content

  init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
    self.spacing = spacing
    self.content = content()
  }

  var body: some View {
    if let spacing {
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

private struct HarnessCapsuleGlassModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .glassEffect(.regular, in: .capsule)
  }
}

extension View {
  func harnessCapsuleGlass() -> some View {
    modifier(HarnessCapsuleGlassModifier())
  }
}
