import SwiftUI

enum ToolbarBaselineRegion: Hashable {
  case sidebar
}

private enum ToolbarBaselineCoordinateSpace {
  static let name = "harness.toolbar-baseline"
}

private struct ToolbarBaselineFramePreferenceKey: PreferenceKey {
  static let defaultValue: [ToolbarBaselineRegion: CGRect] = [:]

  static func reduce(
    value: inout [ToolbarBaselineRegion: CGRect],
    nextValue: () -> [ToolbarBaselineRegion: CGRect]
  ) {
    value.merge(nextValue(), uniquingKeysWith: { _, next in next })
  }
}

private struct ToolbarBaselineFrameModifier: ViewModifier {
  let region: ToolbarBaselineRegion

  func body(content: Content) -> some View {
    content.background {
      GeometryReader { proxy in
        Color.clear.preference(
          key: ToolbarBaselineFramePreferenceKey.self,
          value: [
            region: proxy.frame(in: .named(ToolbarBaselineCoordinateSpace.name))
          ]
        )
      }
    }
  }
}

private struct ToolbarBaselineOverlayModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .coordinateSpace(name: ToolbarBaselineCoordinateSpace.name)
      .overlayPreferenceValue(
        ToolbarBaselineFramePreferenceKey.self,
        alignment: .topLeading
      ) { frames in
        ToolbarBaselineOverlay(leadingInset: frames[.sidebar]?.maxX ?? 0)
      }
  }
}

struct ToolbarBaselineOverlay: View {
  let leadingInset: CGFloat

  private var sidebarMaxX: CGFloat {
    let raw = max(leadingInset, 0)
    return (raw / 4).rounded() * 4
  }

  var body: some View {
    Group {
      if sidebarMaxX > 0 {
        ToolbarBaselineDivider()
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.leading, sidebarMaxX)
      }
    }
    .allowsHitTesting(false)
  }
}

private struct ToolbarBaselineDivider: View {
  var body: some View {
    Divider()
      .frame(height: 1)
      .accessibilityFrameMarker(HarnessMonitorAccessibility.toolbarBaselineDivider)
  }
}

extension View {
  func toolbarBaselineFrame(_ region: ToolbarBaselineRegion) -> some View {
    modifier(ToolbarBaselineFrameModifier(region: region))
  }

  func toolbarBaselineOverlay() -> some View {
    modifier(ToolbarBaselineOverlayModifier())
  }

  func toolbarBaselineOverlay(leadingInset: CGFloat) -> some View {
    overlay(alignment: .topLeading) {
      ToolbarBaselineOverlay(leadingInset: leadingInset)
    }
  }
}
