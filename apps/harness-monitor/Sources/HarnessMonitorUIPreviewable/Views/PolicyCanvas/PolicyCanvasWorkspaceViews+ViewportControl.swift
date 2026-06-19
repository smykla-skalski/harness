// Companion to PolicyCanvasWorkspaceViews.swift.
// Viewport scroll, centering, selection-focus, validation, and command-focus helpers.
// Accesses @State private storage via the internal bridge accessors defined in the primary file.
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

extension PolicyCanvasViewport {
  @MainActor
  func bindCommandFocus() {
    bindZoomFocusDispatcher()
    bindLayoutFocusDispatcher()
    bindSaveFocusDispatcher()
    let nextFocus = policyCanvasCommandFocus(
      zoomFocusDispatcher: bridgeZoomFocusDispatcher,
      canReflow: viewModel.canReflowLayout,
      layoutFocusDispatcher: bridgeLayoutFocusDispatcher,
      canSave: canSave,
      saveFocusDispatcher: bridgeSaveFocusDispatcher
    )
    guard bridgeCommandFocus != nextFocus else {
      return
    }
    bridgeCommandFocus = nextFocus
  }
  @MainActor
  func centerViewportAfterRouteStateSettles(
    viewportSize: CGSize,
    routeOutput: PolicyCanvasRouteWorkerOutput,
    currentRouteKey: PolicyCanvasRouteWorkerKey
  ) async {
    await Task.yield()
    guard !Task.isCancelled else {
      return
    }
    centerViewportIfNeeded(
      viewportSize: viewportSize,
      routeOutput: routeOutput,
      currentRouteKey: currentRouteKey
    )
  }
  func centerViewportIfNeeded(
    viewportSize: CGSize,
    routeOutput: PolicyCanvasRouteWorkerOutput,
    currentRouteKey: PolicyCanvasRouteWorkerKey
  ) {
    guard
      let plan = policyCanvasViewportCenteringPlan(
        input: PolicyCanvasViewportCenteringPlanInput(
          viewModel: viewModel,
          viewportSize: viewportSize,
          routeOutput: routeOutput,
          currentRouteKey: currentRouteKey,
          appliedRouteKey: policyCanvasViewportResolvedRouteCache(
            routeCache: bridgeRouteCache,
            routeKey: currentRouteKey,
            pipelineIdentity: viewModel.pipelineIdentity,
            routeSeed: routeSeed
          ).appliedRouteKey,
          storedPipelineStateRaw: storedPipelineStateRaw,
          suppressesSceneStorage: suppressesSceneStorage,
          hasAppliedRestoredSceneZoom: bridgeHasAppliedRestoredSceneZoom
        )
      )
    else {
      return
    }
    if let targetZoom = plan.targetZoom, abs(targetZoom - viewModel.zoom) > 0.001 {
      viewModel.setZoom(targetZoom)
    }
    bridgeHasAppliedRestoredSceneZoom = plan.appliedRestoredSceneZoom
    let viewportCenteringGeneration = viewModel.viewportCenteringGeneration
    if plan.defersScrollUntilNextRunloop {
      Task { @MainActor in
        await Task.yield()
        await Task.yield()
        guard
          viewModel.viewportCenteringGeneration == viewportCenteringGeneration,
          viewModel.hasPendingViewportCenteringRequest
        else {
          return
        }
        requestViewportScroll(
          target: .centeredDocumentAnchor(plan.anchorPoint),
          viewportCenteringGenerationToConsume: viewportCenteringGeneration
        )
      }
      return
    }
    requestViewportScroll(
      target: .contentOrigin(plan.anchorPoint),
      viewportCenteringGenerationToConsume: viewportCenteringGeneration
    )
  }
  func focusSelectionIfNeeded(
    request: PolicyCanvasViewportSelectionFocusRequest?,
    routeOutput: PolicyCanvasRouteWorkerOutput
  ) {
    guard
      let plan = policyCanvasViewportSelectionFocusPlan(
        request: request,
        handledRequestID: bridgeHandledSelectionFocusRequestID,
        viewModel: viewModel,
        routeOutput: routeOutput
      )
    else {
      return
    }
    bridgeHandledSelectionFocusRequestID = plan.handledRequestID
    Task { @MainActor in
      await Task.yield()
      await Task.yield()
      requestViewportScroll(target: .centeredDocumentAnchor(plan.anchorPoint))
    }
  }
  func bindZoomFocusDispatcher() {
    bridgeZoomFocusDispatcher = policyCanvasZoomFocusDispatcher(viewModel: viewModel)
  }
  func bindLayoutFocusDispatcher() {
    bridgeLayoutFocusDispatcher = policyCanvasLayoutFocusDispatcher(viewModel: viewModel)
  }
  func bindSaveFocusDispatcher() {
    bridgeSaveFocusDispatcher = policyCanvasSaveFocusDispatcher(saveDraft: saveDraft)
  }
  @MainActor
  func rebuildValidation() async {
    bridgeValidationGeneration &+= 1
    let generation = bridgeValidationGeneration
    let output = await policyCanvasViewportValidationPresentation(
      worker: bridgeValidationWorker,
      viewModel: viewModel
    )
    guard !Task.isCancelled, bridgeValidationGeneration == generation else {
      return
    }
    viewModel.applyValidationPresentation(output)
  }
  func requestViewportScroll(
    target: PolicyCanvasViewportScrollTarget,
    viewportCenteringGenerationToConsume: UInt64? = nil
  ) {
    bridgeScrollApplicatorRequestID &+= 1
    bridgeScrollApplicatorRequest = PolicyCanvasViewportScrollRequest(
      id: bridgeScrollApplicatorRequestID,
      target: target,
      viewportCenteringGenerationToConsume: viewportCenteringGenerationToConsume
    )
  }
  func activeViewportScrollRequest(
    _ request: PolicyCanvasViewportScrollRequest?
  ) -> PolicyCanvasViewportScrollRequest? {
    guard
      let request,
      let viewportCenteringGeneration = request.viewportCenteringGenerationToConsume
    else {
      return request
    }
    guard
      viewportCenteringGeneration == viewModel.viewportCenteringGeneration,
      viewModel.hasPendingViewportCenteringRequest
    else {
      return nil
    }
    return request
  }
  func handleViewportScrollRequestFulfilled(
    _ request: PolicyCanvasViewportScrollRequest,
    appliesScroll: Bool
  ) {
    guard bridgeScrollApplicatorRequest?.id == request.id else {
      return
    }
    if let viewportCenteringGeneration = request.viewportCenteringGenerationToConsume {
      _ = viewModel.consumeViewportCenteringRequest(generation: viewportCenteringGeneration)
    }
    _ = appliesScroll
  }
}
