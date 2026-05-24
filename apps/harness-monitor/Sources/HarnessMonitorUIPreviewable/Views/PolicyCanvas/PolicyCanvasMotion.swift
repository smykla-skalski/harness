import SwiftUI

/// Single source of truth for every canvas animation. All `withAnimation` and
/// `.animation(_:value:)` sites in `PolicyCanvas*` files route through these
/// helpers so a `reducedMotion` flag at the call site collapses the entire
/// animation surface to instant.
///
/// Per P19, reduce-motion is a hard rule: every animated path on the canvas
/// must respect `@Environment(\.accessibilityReduceMotion)`. The helpers
/// return `nil` when `reducedMotion` is on; `withAnimation(nil) { ... }` is
/// equivalent to plain assignment (no implicit transaction), and
/// `.animation(nil, value:)` disables the SwiftUI-side interpolation.
///
/// **Lint check (pre-commit grep).** Raw `withAnimation(.spring|.ease)` or
/// `.animation(.spring|.ease)` calls outside this enum bypass the reduce-
/// motion gate. The contract is enforced by grep:
///
/// ```bash
/// grep -rE 'withAnimation\(\.(spring|ease)|\.animation\(\.(spring|ease)' \
///   apps/harness-monitor/Sources/HarnessMonitorUIPreviewable/Views/PolicyCanvas/
/// ```
///
/// must return zero matches. New canvas animations land here as a new
/// `static func` plus matching `static let` constants for the reduce-motion
/// ON / OFF pair so call sites stay through `PolicyCanvasMotion.<helper>`.
///
/// Timings are tuned to read as feedback, not as motion theater:
/// - Drop-end spring (`response: 0.28, dampingFraction: 0.85`) lands a
///   dragged node/group on its new grid position with a single subtle
///   overshoot. Stiffer than the macOS default `.spring()` so it doesn't
///   feel rubbery on a 60Hz drag end.
/// - Zoom transition (`easeInOut, duration: 0.18`) interpolates between
///   grid-locked zoom steps from the chrome buttons. The 0.18s window is
///   short enough that the user perceives a discrete step rather than a
///   crawl; ease-in-out hides the boundary frames at both ends.
/// - Selection mark (`easeOut, duration: 0.12`) fades the stroke color and
///   width up when a node/edge/group becomes selected. Ease-out front-loads
///   the change so the affordance reads instantly; the 120ms tail keeps the
///   transition from feeling like a hard cut.
/// - Overlay (`easeInOut, duration: 0.15`) drives show/hide of the search
///   palette (3J) and the simulation overlay (3L). The shorter window vs.
///   selection avoids stacking a layout animation on top of an opacity
///   animation when the palette mounts.
enum PolicyCanvasMotion {
  /// Drop-end spring used by `endNodeDrag` and `endGroupDrag` callers to
  /// animate the final position write. Returns `nil` under reduce-motion so
  /// the write lands instantly.
  static func spring(reducedMotion: Bool) -> Animation? {
    if reducedMotion {
      return nil
    }
    return .spring(response: 0.28, dampingFraction: 0.85)
  }

  /// Chrome-zoom transition used by `zoomIn`/`zoomOut`/`resetZoom` callers.
  /// Live magnify gesture deliberately bypasses this helper — animating the
  /// per-frame magnification write would feel laggy against the trackpad.
  static func zoomTransition(reducedMotion: Bool) -> Animation? {
    if reducedMotion {
      return nil
    }
    return .easeInOut(duration: 0.18)
  }

  /// Selection-mark transition used to fade the stroke color/width on
  /// nodes, edges, and groups when selection flips. Applied as an
  /// `.animation(_:value:)` modifier so a sibling layer that re-renders for
  /// an unrelated reason doesn't sweep this transition into its frame.
  ///
  /// Call sites usually go through `View.policyCanvasSelectionMark(value:
  /// reducedMotion:)` which hoists the lookup out of the body so the
  /// per-frame construction collapses to a `static let` reference at drag
  /// tick rates.
  static func selectionMark(reducedMotion: Bool) -> Animation? {
    reducedMotion ? Self.selectionMarkDisabled : Self.selectionMarkEnabled
  }

  /// Hoisted selection-mark animation. Constructed once at class init so the
  /// node/edge/group bodies don't allocate a fresh `Animation` per body
  /// pass during a 60Hz drag tick across N selected components.
  static let selectionMarkEnabled: Animation? = .easeOut(duration: 0.12)

  /// Hoisted reduce-motion variant. Explicit `nil` keeps the call sites
  /// uniform: `reducedMotion ? selectionMarkDisabled : selectionMarkEnabled`
  /// matches the structure of the rest of the helpers without a branch
  /// inside the body.
  static let selectionMarkDisabled: Animation? = nil

  // `overlay` and `groupAcceptFlash` previously lived here. The overlay
  // helper had zero production call sites (the search palette and
  // simulation overlay both mount without an implicit animation), and 4K's
  // P36 group accept-flash reads `\.accessibilityReduceMotion` directly
  // rather than threading through this enum. Both will land back if their
  // real callers do.
}

/// Environment value carrying the resolved reduce-motion bit down the canvas
/// view tree. Optional with a `nil` default so a sibling layer rendered
/// outside the `PolicyCanvasView` root (preview that mounts a single layer,
/// future canvas chrome embedded in a different scene) does not silently
/// inherit `false` and ignore the user's system reduce-motion setting.
///
/// **Consumer contract.** Read this env _and_ `\.accessibilityReduceMotion`
/// and fall back to the system flag when this env is `nil`:
///
/// ```swift
/// @Environment(\.policyCanvasReducedMotion) private var canvasReducedMotion
/// @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
///
/// private var reducedMotion: Bool {
///   canvasReducedMotion ?? systemReduceMotion
/// }
/// ```
///
/// **Test-override hook.** Seeding `.environment(\.policyCanvasReducedMotion,
/// true)` from a test overrides the resolved value even when the system
/// flag is off. The root canvas view (`PolicyCanvasView`) seeds the env
/// from its own `@Environment(\.accessibilityReduceMotion)` read so nested
/// layers see the system bit at runtime.
private struct PolicyCanvasReducedMotionKey: EnvironmentKey {
  static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
  /// Resolved reduce-motion flag for the canvas surface, with `nil` meaning
  /// "no canvas-scoped override — fall back to `\.accessibilityReduceMotion`
  /// at the consumer". The canvas root rebinds the value from the system
  /// accessibility setting; tests can seed an explicit `true`/`false` via
  /// `.environment(\.policyCanvasReducedMotion, _:)` to override both.
  var policyCanvasReducedMotion: Bool? {
    get { self[PolicyCanvasReducedMotionKey.self] }
    set { self[PolicyCanvasReducedMotionKey.self] = newValue }
  }
}

extension View {
  /// Applies the selection-mark animation gated by the reduce-motion flag,
  /// keyed on `value`. The `Animation?` value comes from a `static let` on
  /// `PolicyCanvasMotion`, so the call site does not rebuild an animation
  /// per body pass during a 60Hz drag tick across N selected nodes.
  func policyCanvasSelectionMark<V: Equatable>(
    value: V,
    reducedMotion: Bool
  ) -> some View {
    self.animation(PolicyCanvasMotion.selectionMark(reducedMotion: reducedMotion), value: value)
  }
}
