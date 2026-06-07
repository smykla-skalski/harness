import CoreGraphics
import HarnessMonitorPolicyCanvasAlgorithms

struct PolicyCanvasViewportRouteCache {
  var worker = PolicyCanvasRouteWorker()
  var generation: UInt64 = 0
  var appliedRouteKey: PolicyCanvasRouteWorkerKey?
  var cachedOutput = PolicyCanvasRouteWorkerOutput.empty
  var outputsByCanvasIdentity:
    [String: (output: PolicyCanvasRouteWorkerOutput, nodePositionsByID: [String: CGPoint])] = [:]
  var cachedNodePositionsByID: [String: CGPoint] = [:]
  var cachedCanvasIdentity: String?

  mutating func clear(pipelineIdentity: String?) {
    appliedRouteKey = nil
    cachedOutput = .empty
    cachedNodePositionsByID = [:]
    cachedCanvasIdentity = pipelineIdentity
  }

  mutating func nextGeneration() -> UInt64 {
    generation &+= 1
    return generation
  }

  func generationMatches(_ generation: UInt64) -> Bool {
    self.generation == generation
  }

  mutating func update(
    routeKey: PolicyCanvasRouteWorkerKey?,
    pipelineIdentity: String?,
    output: PolicyCanvasRouteWorkerOutput,
    nodePositionsByID: [String: CGPoint]
  ) {
    cachedCanvasIdentity = pipelineIdentity
    cachedNodePositionsByID = nodePositionsByID
    if cachedOutput.signature != output.signature {
      cachedOutput = output
    }
    if let pipelineIdentity {
      outputsByCanvasIdentity[pipelineIdentity] = (output, nodePositionsByID)
    }
    appliedRouteKey = routeKey
  }
}
