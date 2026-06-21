import HarnessMonitorPolicyCanvasAlgorithms
import OSLog
import SwiftUI

actor PolicyCanvasRouteWorker {
  static let signposter = OSSignposter(
    subsystem: "io.harnessmonitor",
    category: "policy-canvas.perf"
  )

  let router: any PolicyCanvasEdgeRouter
  var cachedInput: PolicyCanvasRouteWorkerInput?
  var cachedOutput: PolicyCanvasRouteWorkerOutput = .empty

  init(
    router: any PolicyCanvasEdgeRouter = policyCanvasDefaultEdgeRouter()
  ) {
    self.router = router
  }

  func compute(input: PolicyCanvasRouteWorkerInput) -> PolicyCanvasRouteWorkerOutput {
    guard input != cachedInput else {
      return cachedOutput
    }
    let prepared = PolicyCanvasPreparedRouteInput(input: input)
    let signpostID = Self.signposter.makeSignpostID()
    let interval = Self.signposter.beginInterval(
      "policy_canvas.routes.compute",
      id: signpostID,
      "nodes=\(input.nodes.count, privacy: .public) edges=\(input.edges.count, privacy: .public)"
    )
    defer {
      Self.signposter.endInterval(
        "policy_canvas.routes.compute",
        interval,
        "routes=\(self.cachedOutput.routes.count, privacy: .public)"
      )
    }

    let nodeIndex = prepared.nodeIndex
    let computation = prepared.routeComputation(
      router: router,
      algorithmSelection: input.algorithmSelection
    )
    cachedInput = input
    cachedOutput = output(
      prepared: prepared,
      nodeIndex: nodeIndex,
      computation: computation
    )
    return cachedOutput
  }

  /// Re-route only the edges incident to the moved nodes, reusing `previous` for
  /// the rest. Used by the live drag recompute so a node drag routes a handful of
  /// edges per tick instead of reconverging the whole graph. Falls back to a full
  /// `compute` when selective routing does not apply (topology changed, or no
  /// edge is incident to the moved nodes).
  func computeSelective(
    input: PolicyCanvasRouteWorkerInput,
    movedNodeIDs: Set<String>,
    previous: PolicyCanvasRouteWorkerOutput
  ) -> PolicyCanvasRouteWorkerOutput {
    let prepared = PolicyCanvasPreparedRouteInput(input: input)
    let nodeIndex = prepared.nodeIndex
    guard
      let computation = prepared.selectiveRouteComputation(
        router: router,
        algorithmSelection: input.algorithmSelection,
        movedNodeIDs: movedNodeIDs,
        previousRoutes: previous.routes,
        previousPortMarkerLayout: previous.portMarkerLayout
      )
    else {
      return compute(input: input)
    }
    return output(prepared: prepared, nodeIndex: nodeIndex, computation: computation)
  }

  func waitForIdle() async {}

  static func edgeLabelsByID(
    _ entries: [PolicyCanvasAccessibilityEdgeEntry]
  ) -> [String: String] {
    Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.label) })
  }

  private func output(
    prepared: PolicyCanvasPreparedRouteInput,
    nodeIndex: [String: PolicyCanvasRouteNode],
    computation: PolicyCanvasPreparedRouteComputation
  ) -> PolicyCanvasRouteWorkerOutput {
    let accessibilityEdgeEntries = prepared.accessibilityEdgeEntries(nodeIndex: nodeIndex)
    let nodeAccessibilityValuesByID = prepared.nodeAccessibilityValuesByID(nodeIndex: nodeIndex)
    let accessibilityNodeEntries = prepared.accessibilityNodeEntries()
    let connectTargetsByNodeID = prepared.connectTargetsByNodeID()
    return PolicyCanvasRouteWorkerOutput(
      routes: computation.routes,
      labelPositions: computation.labelPositions,
      portVisibility: computation.portVisibility,
      portMarkerLayout: computation.portMarkerLayout,
      visibleBounds: computation.visibleBounds,
      contentSize: policyCanvasVisibleContentSize(visibleBounds: computation.visibleBounds),
      accessibilityEdgeLabelsByID: Self.edgeLabelsByID(accessibilityEdgeEntries),
      accessibilityNodeEntries: accessibilityNodeEntries,
      accessibilityEdgeEntries: accessibilityEdgeEntries,
      nodeAccessibilityValuesByID: nodeAccessibilityValuesByID,
      connectTargetsByNodeID: connectTargetsByNodeID
    )
  }
}
