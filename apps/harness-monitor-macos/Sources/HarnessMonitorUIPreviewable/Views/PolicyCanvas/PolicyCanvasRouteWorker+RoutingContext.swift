import SwiftUI

struct PolicyCanvasDisplayedRouteEdgeContext {
  let edge: PolicyCanvasEdge
  let source: CGPoint
  let target: CGPoint
  let routeLane: Int
  let sourceFanoutLane: Int
  let targetFanoutLane: Int
  let sourceTerminalSlot: PolicyCanvasRouteEndpointSlot
  let targetTerminalSlot: PolicyCanvasRouteEndpointSlot
}

struct PolicyCanvasDisplayedRouteSharedContext {
  let portMarkerLayout: PolicyCanvasPortMarkerLayout?
  let nodeIndex: [String: PolicyCanvasRouteNode]
  let obstacles: [CGRect]
  let router: any PolicyCanvasEdgeRouter
}
