import SwiftUI

/// On macOS the system manages search-field minimization automatically;
/// `.searchToolbarBehavior(.minimize)` is iOS / visionOS only in the
/// macOS 26 SDK, so this modifier is intentionally a no-op for Monitor's
/// macOS target. The named modifier still documents the call site and
/// gives a single place to wire in any future macOS opt-in without
/// touching `AppSearchHost`.
struct MinimizableSearchToolbarBehavior: ViewModifier {
  func body(content: Content) -> some View {
    content
  }
}

extension View {
  /// Convenience wrapper around ``MinimizableSearchToolbarBehavior``.
  func harnessMinimizableSearchToolbar() -> some View {
    modifier(MinimizableSearchToolbarBehavior())
  }
}
