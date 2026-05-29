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
  @Environment(\.colorScheme)
  private var colorScheme
  @Environment(\.policyCanvasReducedMotion)
  private var canvasReducedMotion
  @Environment(\.accessibilityReduceMotion)
  private var systemReduceMotion

  private var reducedMotion: Bool {
    canvasReducedMotion ?? systemReduceMotion
  }

  private var zoomPercentageText: String {
    "\(Int((viewModel.zoom * 100).rounded()))%"
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
      .frame(minWidth: 24, minHeight: 24)
      .contentShape(Rectangle())
      .accessibilityLabel("Zoom out")
      .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasZoomOutButton)

      Text(zoomPercentageText)
        .scaledFont(.caption.monospacedDigit().weight(.semibold))
        .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
        .frame(width: 46)
        .accessibilityLabel(zoomPercentageText)
        .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasZoomValue)

      Button {
        withAnimation(PolicyCanvasMotion.zoomTransition(reducedMotion: reducedMotion)) {
          viewModel.zoomIn()
        }
      } label: {
        Image(systemName: "plus.magnifyingglass")
      }
      .frame(minWidth: 24, minHeight: 24)
      .contentShape(Rectangle())
      .accessibilityLabel("Zoom in")
      .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasZoomInButton)

      Button {
        withAnimation(PolicyCanvasMotion.zoomTransition(reducedMotion: reducedMotion)) {
          viewModel.resetZoom()
        }
      } label: {
        Image(systemName: "arrow.counterclockwise")
      }
      .frame(minWidth: 24, minHeight: 24)
      .contentShape(Rectangle())
      .accessibilityLabel("Reset zoom to 100 percent")
      .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasZoomResetButton)
    }
    .harnessActionButtonStyle(variant: .borderless)
    .controlSize(.regular)
    .padding(.horizontal, 10)
    .padding(.vertical, 4)
    .frame(minHeight: PolicyCanvasVisualStyle.floatingControlMinHeight)
    .background(
      PolicyCanvasVisualStyle.floatingControlBackground(colorScheme),
      in: RoundedRectangle(cornerRadius: HarnessMonitorTheme.pillCornerRadius)
    )
    .overlay {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.pillCornerRadius)
        .stroke(
          PolicyCanvasVisualStyle.floatingControlBorder(colorScheme),
          lineWidth: PolicyCanvasVisualStyle.floatingControlBorderLineWidth(colorScheme)
        )
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasZoomControls)
  }
}
