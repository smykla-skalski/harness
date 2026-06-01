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
    router: any PolicyCanvasEdgeRouter = PolicyCanvasMemoizedRouter(
      inner: PolicyCanvasVisibilityRouter()
    )
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

    let algorithms = PolicyCanvasAlgorithmRegistry.routingAlgorithms(for: input.algorithmSelection)
    let selectedRouter = selectedRouter(for: input, algorithms: algorithms)
    let nodeIndex = prepared.nodeIndex
    let routeState = convergedRouteState(
      prepared: prepared,
      nodeIndex: nodeIndex,
      router: selectedRouter,
      algorithms: algorithms
    )
    let routes = algorithms.routePostProcessing.processRoutes(
      input: PolicyCanvasRoutePostProcessingInput(prepared: prepared, routes: routeState.routes)
    )
    cachedInput = input
    cachedOutput = output(
      prepared: prepared,
      routes: routes,
      portMarkerLayout: routeState.portMarkerLayout,
      nodeIndex: nodeIndex,
      algorithms: algorithms
    )
    return cachedOutput
  }

  func waitForIdle() async {}

  static func edgeLabelsByID(
    _ entries: [PolicyCanvasAccessibilityEdgeEntry]
  ) -> [String: String] {
    Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.label) })
  }

  private func selectedRouter(
    for input: PolicyCanvasRouteWorkerInput,
    algorithms: PolicyCanvasRoutingAlgorithmSet
  ) -> any PolicyCanvasEdgeRouter {
    input.algorithmSelection.algorithmID(for: .edgeRouting)
      == PolicyCanvasAlgorithmDefaults.paddedOrthogonalVisibilityAStar
      ? router
      : algorithms.edgeRouter
  }

  private func convergedRouteState(
    prepared: PolicyCanvasPreparedRouteInput,
    nodeIndex: [String: PolicyCanvasRouteNode],
    router selectedRouter: any PolicyCanvasEdgeRouter,
    algorithms: PolicyCanvasRoutingAlgorithmSet
  ) -> PolicyCanvasRouteComputationState {
    let initialRoutes = algorithms.routeSelection.selectRoutes(
      input: PolicyCanvasRouteSelectionInput(
        prepared: prepared,
        router: selectedRouter,
        portMarkerLayout: nil
      )
    )
    var state = PolicyCanvasRouteComputationState(
      routes: initialRoutes,
      portMarkerLayout: algorithms.portMarkerPlacement.placeMarkers(
        input: PolicyCanvasPortMarkerPlacementInput(
          prepared: prepared,
          routes: initialRoutes,
          nodeIndex: nodeIndex
        )
      )
    )
    var seenLayouts: [PolicyCanvasPortMarkerLayout] = [state.portMarkerLayout]
    for _ in 0..<3 {
      let nextState = nextRouteState(
        current: state,
        prepared: prepared,
        nodeIndex: nodeIndex,
        router: selectedRouter,
        algorithms: algorithms
      )
      if nextState.portMarkerLayout == state.portMarkerLayout {
        return nextState
      }
      if seenLayouts.contains(nextState.portMarkerLayout) {
        return reroutedState(
          portMarkerLayout: nextState.portMarkerLayout,
          prepared: prepared,
          router: selectedRouter,
          algorithms: algorithms
        )
      }
      seenLayouts.append(nextState.portMarkerLayout)
      state = nextState
    }
    return reroutedState(
      portMarkerLayout: state.portMarkerLayout,
      prepared: prepared,
      router: selectedRouter,
      algorithms: algorithms
    )
  }

  private func nextRouteState(
    current: PolicyCanvasRouteComputationState,
    prepared: PolicyCanvasPreparedRouteInput,
    nodeIndex: [String: PolicyCanvasRouteNode],
    router selectedRouter: any PolicyCanvasEdgeRouter,
    algorithms: PolicyCanvasRoutingAlgorithmSet
  ) -> PolicyCanvasRouteComputationState {
    let routes = algorithms.routeSelection.selectRoutes(
      input: PolicyCanvasRouteSelectionInput(
        prepared: prepared,
        router: selectedRouter,
        portMarkerLayout: current.portMarkerLayout
      )
    )
    return PolicyCanvasRouteComputationState(
      routes: routes,
      portMarkerLayout: algorithms.portMarkerPlacement.placeMarkers(
        input: PolicyCanvasPortMarkerPlacementInput(
          prepared: prepared,
          routes: routes,
          nodeIndex: nodeIndex
        )
      )
    )
  }

  private func reroutedState(
    portMarkerLayout: PolicyCanvasPortMarkerLayout,
    prepared: PolicyCanvasPreparedRouteInput,
    router selectedRouter: any PolicyCanvasEdgeRouter,
    algorithms: PolicyCanvasRoutingAlgorithmSet
  ) -> PolicyCanvasRouteComputationState {
    PolicyCanvasRouteComputationState(
      routes: algorithms.routeSelection.selectRoutes(
        input: PolicyCanvasRouteSelectionInput(
          prepared: prepared,
          router: selectedRouter,
          portMarkerLayout: portMarkerLayout
        )
      ),
      portMarkerLayout: portMarkerLayout
    )
  }

  private func output(
    prepared: PolicyCanvasPreparedRouteInput,
    routes: [String: PolicyCanvasEdgeRoute],
    portMarkerLayout: PolicyCanvasPortMarkerLayout,
    nodeIndex: [String: PolicyCanvasRouteNode],
    algorithms: PolicyCanvasRoutingAlgorithmSet
  ) -> PolicyCanvasRouteWorkerOutput {
    let labelPositions = algorithms.labelPlacement.placeLabels(
      input: PolicyCanvasLabelPlacementInput(prepared: prepared, routes: routes)
    )
    let visibleBounds = prepared.visibleBounds(routes: routes, labelPositions: labelPositions)
    let accessibilityEdgeEntries = prepared.accessibilityEdgeEntries(nodeIndex: nodeIndex)
    let nodeAccessibilityValuesByID = prepared.nodeAccessibilityValuesByID(nodeIndex: nodeIndex)
    let accessibilityNodeEntries = prepared.accessibilityNodeEntries()
    let connectTargetsByNodeID = prepared.connectTargetsByNodeID()
    return PolicyCanvasRouteWorkerOutput(
      routes: routes,
      labelPositions: labelPositions,
      portVisibility: prepared.portVisibility(routes: routes, nodeIndex: nodeIndex),
      portMarkerLayout: portMarkerLayout,
      visibleBounds: visibleBounds,
      contentSize: policyCanvasVisibleContentSize(visibleBounds: visibleBounds),
      accessibilityEdgeLabelsByID: Self.edgeLabelsByID(accessibilityEdgeEntries),
      accessibilityNodeEntries: accessibilityNodeEntries,
      accessibilityEdgeEntries: accessibilityEdgeEntries,
      nodeAccessibilityValuesByID: nodeAccessibilityValuesByID,
      connectTargetsByNodeID: connectTargetsByNodeID
    )
  }
}

private struct PolicyCanvasRouteComputationState {
  let routes: [String: PolicyCanvasEdgeRoute]
  let portMarkerLayout: PolicyCanvasPortMarkerLayout
}
