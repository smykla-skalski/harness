import SwiftUI

struct PolicyCanvasViewportHostedContent: View {
  let viewModel: PolicyCanvasViewModel
  let snapshot: PolicyCanvasViewportHostedSnapshot
  let zoom: CGFloat
  let viewportIdentity: String?
  let isActive: Bool
  let isEmpty: Bool
  let request: PolicyCanvasViewportScrollRequest?
  let storedPipelineStateRaw: String
  let suppressesSceneStorage: Bool
  let observationStore: PolicyCanvasViewportObservationStore
  let contentBounds: CGRect
  let minimapVisible: Bool
  let resolvedCanvasColorScheme: ColorScheme?
  let minimapCenteringModeOverride: PolicyCanvasMinimapCenteringMode?
  let showsEdgeLegend: Bool
  let onFulfillRequest: @MainActor @Sendable (PolicyCanvasViewportScrollRequest, Bool) -> Void
  let onZoomChange: @MainActor @Sendable (CGFloat) -> Void
  let onViewportChange: @MainActor @Sendable (PolicyCanvasViewportObservedState, String?) -> Void
  let requestViewportScroll: @MainActor @Sendable (CGPoint) -> Void

  var body: some View {
    PolicyCanvasViewportNativeHost(
      snapshot: snapshot,
      zoom: zoom,
      viewportIdentity: viewportIdentity,
      isActive: isActive,
      isEmpty: isEmpty,
      request: request,
      onFulfillRequest: onFulfillRequest,
      onZoomChange: onZoomChange,
      onViewportChange: onViewportChange
    )
    .clipShape(Rectangle())
    .overlay {
      PolicyCanvasEmptyStatePlaceholder(viewModel: viewModel)
        .policyCanvasResolvedThemeScope(resolvedCanvasColorScheme)
        .allowsHitTesting(false)
    }
    .modifier(
      PolicyCanvasViewportOverlayModifier(
        viewModel: viewModel,
        observationStore: observationStore,
        storedPipelineStateRaw: storedPipelineStateRaw,
        suppressesSceneStorage: suppressesSceneStorage,
        contentBounds: contentBounds,
        minimapVisible: minimapVisible,
        resolvedCanvasColorScheme: resolvedCanvasColorScheme,
        minimapCenteringModeOverride: minimapCenteringModeOverride,
        showsEdgeLegend: showsEdgeLegend,
        requestViewportScroll: requestViewportScroll
      )
    )
  }
}
