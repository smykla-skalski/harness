import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

struct PolicyCanvasViewportOverlayModifier: ViewModifier {
  let viewModel: PolicyCanvasViewModel
  let observationStore: PolicyCanvasViewportObservationStore
  let storedPipelineStateRaw: String
  let suppressesSceneStorage: Bool
  let contentBounds: CGRect
  let minimapVisible: Bool
  let resolvedCanvasColorScheme: ColorScheme?
  let minimapCenteringModeOverride: PolicyCanvasMinimapCenteringMode?
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
              viewportIdentity: viewModel.pipelineIdentity,
              storedPipelineStateRaw: storedPipelineStateRaw,
              suppressesSceneStorage: suppressesSceneStorage,
              contentBounds: contentBounds,
              minimapCenteringModeOverride: minimapCenteringModeOverride
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
