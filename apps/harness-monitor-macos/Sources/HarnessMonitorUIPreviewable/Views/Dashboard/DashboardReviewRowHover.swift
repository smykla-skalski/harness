import SwiftUI

/// Subtle row hover tint for Reviews detail-pane rows that act as full-width
/// buttons (check rows, group headers). Pure background + animation modifier;
/// foreground rendering stays whatever the underlying view set.
struct DashboardReviewRowHoverTint: ViewModifier {
  let isHovered: Bool

  func body(content: Content) -> some View {
    content
      .background(HarnessMonitorTheme.ink.opacity(isHovered ? 0.06 : 0))
      .animation(.easeOut(duration: 0.12), value: isHovered)
  }
}

extension View {
  func harnessReviewRowHoverTint(isHovered: Bool) -> some View {
    modifier(DashboardReviewRowHoverTint(isHovered: isHovered))
  }
}
