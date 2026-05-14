import SwiftUI

/// Bottom-left zoom chrome overlay rendered by `PolicyCanvasViewport`. Three
/// buttons (zoom out, zoom in, reset) drive `PolicyCanvasViewModel.setZoom`
/// through the chrome-only `withAnimation` path — live magnify on the
/// trackpad bypasses this animation in `PolicyCanvasViewport.magnifyGesture`
/// so the per-frame magnification write stays gesture-fresh.
///
/// Extracted from `PolicyCanvasChromeViews.swift` on touch (Wave 4L) to
/// keep the chrome file under the 420-line cap after the P18/P19 reduce-
/// motion wiring landed.
struct PolicyCanvasZoomControls: View {
  let viewModel: PolicyCanvasViewModel
  /// P19 reduce-motion handle for the P18 chrome-zoom transition. Live
  /// magnify gesture in `PolicyCanvasViewport.magnifyGesture` deliberately
  /// bypasses this animation because animating the per-frame magnification
  /// write would feel laggy against the trackpad gesture. Nil fallback reads
  /// the system `\.accessibilityReduceMotion` so callers outside the canvas
  /// root still respect the system setting.
  @Environment(\.policyCanvasReducedMotion) private var canvasReducedMotion
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

  /// Resolved reduce-motion bit. Prefer the canvas-scoped override (set by
  /// `PolicyCanvasView` from the system flag, or by tests via the
  /// environment-override hook) and fall back to the system flag when nil.
  private var reducedMotion: Bool {
    canvasReducedMotion ?? systemReduceMotion
  }

  // The image-only buttons below carry icons that VoiceOver would otherwise
  // read as their SF Symbol names ("minus magnifying glass, button"). The
  // explicit `.accessibilityLabel` calls give the AT user the same intent
  // the sighted user gets from the glyph. The `.keyboardShortcut`s map to
  // legacy app shortcuts; the cross-wave plan tracked in 4M ports these
  // chord-to-action mappings into a `CommandGroup` so the same shortcuts
  // appear in the menu bar. Keep these buttons in lockstep with that
  // migration so the chord wiring stays unique.
  var body: some View {
    HStack(spacing: 6) {
      Button {
        withAnimation(PolicyCanvasMotion.zoomTransition(reducedMotion: reducedMotion)) {
          viewModel.zoomOut()
        }
      } label: {
        Image(systemName: "minus.magnifyingglass")
      }
      .keyboardShortcut("-", modifiers: [.command])
      .accessibilityLabel("Zoom out")
      .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasZoomOutButton)

      Text("\(Int((viewModel.zoom * 100).rounded()))%")
        .scaledFont(.caption.monospacedDigit().weight(.semibold))
        .foregroundStyle(.white.opacity(0.86))
        .frame(width: 46)
        .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasZoomValue)

      Button {
        withAnimation(PolicyCanvasMotion.zoomTransition(reducedMotion: reducedMotion)) {
          viewModel.zoomIn()
        }
      } label: {
        Image(systemName: "plus.magnifyingglass")
      }
      .keyboardShortcut("+", modifiers: [.command])
      .accessibilityLabel("Zoom in")
      .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasZoomInButton)

      Button {
        withAnimation(PolicyCanvasMotion.zoomTransition(reducedMotion: reducedMotion)) {
          viewModel.resetZoom()
        }
      } label: {
        Image(systemName: "arrow.counterclockwise")
      }
      .keyboardShortcut("0", modifiers: [.command])
      .accessibilityLabel("Reset zoom to 100 percent")
      .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasZoomResetButton)
    }
    .harnessActionButtonStyle(variant: .borderless)
    .controlSize(.small)
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(Color.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color.white.opacity(0.12), lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasZoomControls)
  }
}
