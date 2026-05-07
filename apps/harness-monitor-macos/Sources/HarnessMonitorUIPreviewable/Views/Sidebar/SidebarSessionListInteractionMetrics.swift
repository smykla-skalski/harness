import SwiftUI

enum SidebarSessionListInteractionMetrics {
  static let coordinateSpaceName = "sidebar.session-list.interaction"
}

struct SidebarSessionListWhitespaceBoundaryKey: PreferenceKey {
  static let defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

struct SidebarSessionListWhitespaceBoundaryReporter: View {
  var body: some View {
    GeometryReader { proxy in
      Color.clear
        .accessibilityHidden(true)
        .preference(
          key: SidebarSessionListWhitespaceBoundaryKey.self,
          value: proxy.frame(
            in: .named(SidebarSessionListInteractionMetrics.coordinateSpaceName)
          ).maxY
        )
    }
  }
}
