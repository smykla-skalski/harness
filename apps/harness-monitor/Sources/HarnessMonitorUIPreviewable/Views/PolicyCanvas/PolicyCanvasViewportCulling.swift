import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

private let policyCanvasViewportCullGuardBand: CGFloat = 720
private let policyCanvasRouteCullPadding: CGFloat = 48

@MainActor
func policyCanvasViewportCullRect(
  observationStore: PolicyCanvasViewportObservationStore,
  viewportIdentity: String?
) -> CGRect? {
  guard
    let observedState = observationStore.observedState(for: viewportIdentity),
    observedState.visibleContentRect.width > 1,
    observedState.visibleContentRect.height > 1
  else {
    return nil
  }
  return observedState.visibleContentRect.insetBy(
    dx: -policyCanvasViewportCullGuardBand,
    dy: -policyCanvasViewportCullGuardBand
  )
}

func policyCanvasNodeIsVisible(
  _ node: PolicyCanvasNode,
  in cullRect: CGRect?
) -> Bool {
  guard let cullRect else {
    return true
  }
  return policyCanvasNodeFrame(node).intersects(cullRect)
}

func policyCanvasRouteIsVisible(
  _ route: PolicyCanvasEdgeRoute,
  in cullRect: CGRect?
) -> Bool {
  guard let cullRect else {
    return true
  }
  let bounds = policyCanvasRouteBounds(route).insetBy(
    dx: -policyCanvasRouteCullPadding,
    dy: -policyCanvasRouteCullPadding
  )
  return bounds.intersects(cullRect)
}

func policyCanvasLabelIsVisible(
  center: CGPoint,
  size: CGSize,
  in cullRect: CGRect?
) -> Bool {
  guard let cullRect else {
    return true
  }
  let frame = CGRect(
    x: center.x - (size.width / 2),
    y: center.y - (size.height / 2),
    width: size.width,
    height: size.height
  )
  return frame.intersects(cullRect)
}
