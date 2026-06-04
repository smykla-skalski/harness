import SwiftUI

extension PolicyCanvasViewport {
  func policyCanvasMinimapViewportMatchesRestoredSceneState(
    observedState: PolicyCanvasViewportObservedState,
    identity: String?,
    storedPipelineStateRaw: String,
    suppressesSceneStorage: Bool
  ) -> Bool {
    guard
      let restoredViewportRect = PolicyCanvasView.sceneState(
        for: identity,
        raw: storedPipelineStateRaw,
        suppressesSceneStorage: suppressesSceneStorage
      )?
      .viewportRect
    else {
      return false
    }
    return policyCanvasMinimapViewportRectApproximatelyMatches(
      observedState.visibleContentRect,
      restoredViewportRect
    )
  }

  func policyCanvasMinimapViewportRectApproximatelyMatches(
    _ lhs: CGRect,
    _ rhs: CGRect
  ) -> Bool {
    abs(lhs.minX - rhs.minX) < 0.5
      && abs(lhs.minY - rhs.minY) < 0.5
      && abs(lhs.width - rhs.width) < 0.5
      && abs(lhs.height - rhs.height) < 0.5
  }
}
