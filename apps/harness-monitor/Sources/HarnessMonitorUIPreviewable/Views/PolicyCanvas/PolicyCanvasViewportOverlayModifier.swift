import SwiftUI

struct PolicyCanvasViewportOverlayModifier: ViewModifier {
  let viewModel: PolicyCanvasViewModel
  let observationStore: PolicyCanvasViewportObservationStore
  let contentBounds: CGRect
  let minimapVisible: Bool
  let resolvedCanvasColorScheme: ColorScheme?
  let requestViewportScroll: @MainActor (CGPoint) -> Void

  func body(content: Content) -> some View {
    content
      .overlay(alignment: .topLeading) {
        PolicyCanvasEdgeKindLegend()
          .policyCanvasResolvedThemeScope(resolvedCanvasColorScheme)
          .padding(14)
      }
      .overlay(alignment: .bottomLeading) {
        PolicyCanvasZoomControls(viewModel: viewModel)
          .policyCanvasResolvedThemeScope(resolvedCanvasColorScheme)
          .padding(14)
      }
      .overlay(alignment: .bottomTrailing) {
        VStack(alignment: .trailing, spacing: 12) {
          if minimapVisible, !viewModel.isEmpty {
            PolicyCanvasMinimapViewportOverlay(
              viewModel: viewModel,
              observationStore: observationStore,
              contentBounds: contentBounds
            ) { targetOrigin in
              requestViewportScroll(targetOrigin)
            }
          }
          PolicyCanvasShortcutsDisclosure()
        }
        .policyCanvasResolvedThemeScope(resolvedCanvasColorScheme)
        .padding(14)
      }
  }
}
