import Foundation
import HarnessMonitorPolicyCanvasAlgorithms

struct PolicyCanvasViewportSelectionFocusRequest: Equatable {
  let id: UInt64
  let selection: PolicyCanvasSelection
}

struct PolicyCanvasViewportCenteringRouteState: Equatable {
  let currentRouteKey: PolicyCanvasRouteWorkerKey
  let appliedRouteKey: PolicyCanvasRouteWorkerKey?
  let routeOutputSignature: PolicyCanvasRouteWorkerOutputSignature
  let viewportCenteringGeneration: UInt64
}
