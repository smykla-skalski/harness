import SwiftUI

/// Mobile counterpart to the macOS `HarnessMonitorGlassControlGroup`. All glass
/// grouping in the iOS app routes through this wrapper so the raw
/// `GlassEffectContainer` stays in one audited place and reduce-transparency is
/// honored consistently. The filename matches the glass-container lint
/// exclusion (`HarnessMonitor*Glass*.swift`).
struct HarnessMonitorMobileGlassControlGroup<Content: View>: View {
  let spacing: CGFloat?
  private let content: Content
  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency

  init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
    self.spacing = spacing
    self.content = content()
  }

  var body: some View {
    if reduceTransparency {
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
