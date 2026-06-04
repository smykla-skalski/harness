import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

struct PolicyCanvasViewportCenteringPlanInput {
  let viewModel: PolicyCanvasViewModel
  let viewportSize: CGSize
  let routeOutput: PolicyCanvasRouteWorkerOutput
  let currentRouteKey: PolicyCanvasRouteWorkerKey
  let appliedRouteKey: PolicyCanvasRouteWorkerKey?
  let routeOutputIsCurrentGraphProvisional: Bool
  let storedPipelineStateRaw: String
  let suppressesSceneStorage: Bool
  let hasAppliedRestoredSceneZoom: Bool
}

struct PolicyCanvasViewportCenteringPlan {
  let targetZoom: CGFloat?
  let appliedRestoredSceneZoom: Bool
  let anchorPoint: CGPoint
  let defersScrollUntilNextRunloop: Bool
}

@MainActor
func policyCanvasViewportCenteringPlan(
  input: PolicyCanvasViewportCenteringPlanInput
) -> PolicyCanvasViewportCenteringPlan? {
  guard
    input.viewModel.hasPendingViewportCenteringRequest,
    policyCanvasCanCenterViewport(
      isCanvasEmpty: input.viewModel.isEmpty,
      routeOutputSignature: input.routeOutput.signature,
      currentRouteKey: input.currentRouteKey,
      appliedRouteKey: input.appliedRouteKey,
      routeOutputIsCurrentGraphProvisional: input.routeOutputIsCurrentGraphProvisional,
      allowsProvisionalRouteOutput:
        input.viewModel.viewportCenteringBehavior.allowsProvisionalRouteOutput
    )
  else {
    return nil
  }
  let visibleBounds = input.routeOutput.visibleBounds
  let restoredSceneState = PolicyCanvasView.sceneState(
    for: input.viewModel.pipelineIdentity,
    raw: input.storedPipelineStateRaw,
    suppressesSceneStorage: input.suppressesSceneStorage
  )
  let usesRestoredViewportState =
    input.viewModel.viewportCenteringBehavior.usesRestoredViewportOrigin
  let targetZoom: CGFloat?
  let appliedRestoredSceneZoom: Bool
  if usesRestoredViewportState, let restoredSceneState, !input.hasAppliedRestoredSceneZoom {
    targetZoom = PolicyCanvasViewModel.sanitizedZoom(
      CGFloat(restoredSceneState.zoom),
      fallback: input.viewModel.zoom
    )
    appliedRestoredSceneZoom = true
  } else if restoredSceneState == nil || !usesRestoredViewportState {
    let fittedZoom = input.viewModel.fittedInitialZoom(
      for: input.viewportSize,
      contentBounds: visibleBounds
    )
    targetZoom =
      input.viewModel.isEmpty ? input.viewModel.zoom : min(input.viewModel.zoom, fittedZoom)
    appliedRestoredSceneZoom = input.hasAppliedRestoredSceneZoom
  } else {
    targetZoom = nil
    appliedRestoredSceneZoom = input.hasAppliedRestoredSceneZoom
  }
  if usesRestoredViewportState, let restoredViewportOrigin = restoredSceneState?.viewportOrigin {
    return PolicyCanvasViewportCenteringPlan(
      targetZoom: targetZoom,
      appliedRestoredSceneZoom: appliedRestoredSceneZoom,
      anchorPoint: restoredViewportOrigin,
      defersScrollUntilNextRunloop: false
    )
  }
  let selectionAnchorPoint = policyCanvasViewportCenteringSelectionDocumentAnchorPoint(
    behavior: input.viewModel.viewportCenteringBehavior,
    selection: input.viewModel.selection,
    viewModel: input.viewModel,
    routeOutput: input.routeOutput
  )
  return PolicyCanvasViewportCenteringPlan(
    targetZoom: targetZoom,
    appliedRestoredSceneZoom: appliedRestoredSceneZoom,
    anchorPoint: selectionAnchorPoint
      ?? policyCanvasInitialViewportDocumentAnchorPoint(visibleBounds: visibleBounds),
    defersScrollUntilNextRunloop: true
  )
}

struct PolicyCanvasViewportSelectionFocusPlan {
  let handledRequestID: UInt64
  let anchorPoint: CGPoint
}

@MainActor
func policyCanvasViewportSelectionFocusPlan(
  request: PolicyCanvasViewportSelectionFocusRequest?,
  handledRequestID: UInt64?,
  viewModel: PolicyCanvasViewModel,
  routeOutput: PolicyCanvasRouteWorkerOutput
) -> PolicyCanvasViewportSelectionFocusPlan? {
  guard let request, handledRequestID != request.id else {
    return nil
  }
  guard
    let anchorPoint = policyCanvasSelectionViewportDocumentAnchorPoint(
      selection: request.selection,
      viewModel: viewModel,
      routeOutput: routeOutput
    )
  else {
    return nil
  }
  return PolicyCanvasViewportSelectionFocusPlan(
    handledRequestID: request.id,
    anchorPoint: anchorPoint
  )
}
