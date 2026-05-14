import SwiftUI

/// Bottom-leading viewport zoom HUD. The visible chrome owns one keyboard
/// chord per Button — Cmd-- (zoom out), Cmd-+ (zoom in), Cmd-0 (reset) —
/// and the alternate Cmd-= chord for zoom-in is registered at the scene
/// level through `harnessPolicyCanvasZoomFocus` so the menu / Mac-standard
/// keyboard convention works without a hidden Button anti-pattern.
///
/// Trackpad pinch zoom lives on `PolicyCanvasViewport.magnifyGesture` and
/// is the primary zoom gesture. The chrome buttons drive
/// `PolicyCanvasViewModel.setZoom` through a `withAnimation(zoomTransition)`
/// path so each click animates; live pinch bypasses the animation so the
/// per-frame magnification stays gesture-fresh.
struct PolicyCanvasZoomControls: View {
  let viewModel: PolicyCanvasViewModel
  @Environment(\.policyCanvasReducedMotion) private var canvasReducedMotion
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

  private var reducedMotion: Bool {
    canvasReducedMotion ?? systemReduceMotion
  }

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
