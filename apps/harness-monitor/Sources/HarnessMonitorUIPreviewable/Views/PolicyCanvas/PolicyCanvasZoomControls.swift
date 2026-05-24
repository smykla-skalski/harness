import SwiftUI

/// Bottom-leading viewport zoom HUD. The buttons stay clickable for users who
/// prefer mouse interaction, but the keyboard chords (Cmd-=, Cmd--, Cmd-0)
/// are bound exclusively at scene level via `policyCanvasZoomCommands` in
/// `HarnessMonitorAppCommands`. Centralizing the chords keeps one source of
/// truth for the View-menu entries and avoids the previous conflict where
/// both the HUD buttons and the app-wide text-size shortcuts bound the same
/// keys.
///
/// Trackpad pinch zoom lives on `PolicyCanvasViewport.magnifyGesture` and
/// is the primary zoom gesture. The HUD buttons drive
/// `PolicyCanvasViewModel.setZoom` through a `withAnimation(zoomTransition)`
/// path so each click animates; live pinch bypasses the animation so the
/// per-frame magnification stays gesture-fresh.
struct PolicyCanvasZoomControls: View {
  let viewModel: PolicyCanvasViewModel
  @Environment(\.policyCanvasReducedMotion)
  private var canvasReducedMotion
  @Environment(\.accessibilityReduceMotion)
  private var systemReduceMotion

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
      .accessibilityLabel("Zoom in")
      .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasZoomInButton)

      Button {
        withAnimation(PolicyCanvasMotion.zoomTransition(reducedMotion: reducedMotion)) {
          viewModel.resetZoom()
        }
      } label: {
        Image(systemName: "arrow.counterclockwise")
      }
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
