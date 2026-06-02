import Foundation

struct PolicyCanvasLayoutAlgorithmSet: Sendable {
  let cycleBreaking: any PolicyCanvasCycleBreakingAlgorithm
  let rankAssignment: any PolicyCanvasRankAssignmentAlgorithm
  let longEdgeNormalization: any PolicyCanvasLongEdgeNormalizationAlgorithm
  let layerOrdering: any PolicyCanvasLayerOrderingAlgorithm
  let coordinateAssignment: any PolicyCanvasCoordinateAssignmentAlgorithm
  let groupPlacement: any PolicyCanvasGroupPlacementAlgorithm
  let layoutPostProcessing: any PolicyCanvasLayoutPostProcessingAlgorithm
  let metrics: any PolicyCanvasMetricsAlgorithm
}

struct PolicyCanvasRoutingAlgorithmSet: Sendable {
  let portMarkerPlacement: any PolicyCanvasPortMarkerPlacementAlgorithm
  let edgeRouter: any PolicyCanvasEdgeRouter
  let routeSelection: any PolicyCanvasRouteSelectionAlgorithm
  let routePostProcessing: any PolicyCanvasRoutePostProcessingAlgorithm
  let labelPlacement: any PolicyCanvasEdgeLabelPlacementAlgorithm
}

public func policyCanvasUsesSingleFedTerminalAlignment(
  _ selection: PolicyCanvasAlgorithmSelection
) -> Bool {
  PolicyCanvasAlgorithmRegistry.usesSingleFedTerminalAlignment(selection)
}

enum PolicyCanvasAlgorithmRegistry {
  static func isHarnessCurrentLayout(_ selection: PolicyCanvasAlgorithmSelection) -> Bool {
    PolicyCanvasAlgorithmDefaults.layoutStages.allSatisfy { stage in
      selection.algorithmID(for: stage)
        == PolicyCanvasAlgorithmDefaults.harnessCurrentID(for: stage)
    }
  }

  static func usesSingleFedTerminalAlignment(_ selection: PolicyCanvasAlgorithmSelection) -> Bool {
    selection.algorithmID(for: .layoutPostProcessing)
      == PolicyCanvasAlgorithmDefaults.terminalCombAndSingleFedAlignment
  }

  static func layoutAlgorithms(
    for selection: PolicyCanvasAlgorithmSelection
  ) -> PolicyCanvasLayoutAlgorithmSet {
    PolicyCanvasLayoutAlgorithmSet(
      cycleBreaking: cycleBreakingAlgorithm(for: selection.algorithmID(for: .cycleBreaking)),
      rankAssignment: rankAssignmentAlgorithm(for: selection.algorithmID(for: .rankAssignment)),
      longEdgeNormalization: longEdgeNormalizationAlgorithm(
        for: selection.algorithmID(for: .longEdgeNormalization)
      ),
      layerOrdering: layerOrderingAlgorithm(for: selection.algorithmID(for: .layerOrdering)),
      coordinateAssignment: coordinateAssignmentAlgorithm(
        for: selection.algorithmID(for: .coordinateAssignment)
      ),
      groupPlacement: groupPlacementAlgorithm(for: selection.algorithmID(for: .groupPlacement)),
      layoutPostProcessing: layoutPostProcessingAlgorithm(
        for: selection.algorithmID(for: .layoutPostProcessing)
      ),
      metrics: metricsAlgorithm(for: selection.algorithmID(for: .metrics))
    )
  }

  static func routingAlgorithms(
    for selection: PolicyCanvasAlgorithmSelection
  ) -> PolicyCanvasRoutingAlgorithmSet {
    PolicyCanvasRoutingAlgorithmSet(
      portMarkerPlacement: portMarkerPlacementAlgorithm(
        for: selection.algorithmID(for: .portMarkerPlacement)
      ),
      edgeRouter: edgeRouterAlgorithm(for: selection.algorithmID(for: .edgeRouting)),
      routeSelection: routeSelectionAlgorithm(for: selection.algorithmID(for: .routeSelection)),
      routePostProcessing: routePostProcessingAlgorithm(
        for: selection.algorithmID(for: .routePostProcessing)
      ),
      labelPlacement: labelPlacementAlgorithm(for: selection.algorithmID(for: .labelPlacement))
    )
  }

  private static func cycleBreakingAlgorithm(
    for id: PolicyCanvasAlgorithmID
  ) -> any PolicyCanvasCycleBreakingAlgorithm {
    switch id {
    case PolicyCanvasAlgorithmDefaults.greedyFeedbackArcReversal:
      PolicyCanvasGreedyFeedbackArcReversal()
    default:
      PolicyCanvasDepthFirstBackEdgeReversal()
    }
  }

  private static func rankAssignmentAlgorithm(
    for id: PolicyCanvasAlgorithmID
  ) -> any PolicyCanvasRankAssignmentAlgorithm {
    switch id {
    case PolicyCanvasAlgorithmDefaults.harnessGroupAwareLongestPath:
      PolicyCanvasHarnessGroupAwareLongestPathLayering()
    default:
      PolicyCanvasLongestPathLayering()
    }
  }

  private static func longEdgeNormalizationAlgorithm(
    for id: PolicyCanvasAlgorithmID
  ) -> any PolicyCanvasLongEdgeNormalizationAlgorithm {
    switch id {
    case PolicyCanvasAlgorithmDefaults.interpolatedDummyChain:
      PolicyCanvasInterpolatedDummyChainNormalization()
    default:
      PolicyCanvasUnitDummyChainNormalization()
    }
  }

  private static func layerOrderingAlgorithm(
    for id: PolicyCanvasAlgorithmID
  ) -> any PolicyCanvasLayerOrderingAlgorithm {
    switch id {
    case PolicyCanvasAlgorithmDefaults.seededBarycenterTranspose:
      PolicyCanvasSeededBarycenterTransposeReduction()
    case PolicyCanvasAlgorithmDefaults.barycenterTransposeCrossingReduction:
      PolicyCanvasBarycenterTransposeCrossingReduction()
    default:
      PolicyCanvasBarycenterCrossingReduction()
    }
  }

  private static func coordinateAssignmentAlgorithm(
    for id: PolicyCanvasAlgorithmID
  ) -> any PolicyCanvasCoordinateAssignmentAlgorithm {
    switch id {
    case PolicyCanvasAlgorithmDefaults.layeredGridCoordinateAssignment:
      PolicyCanvasLayeredGridCoordinateAssignment()
    default:
      PolicyCanvasBrandesKopfCoordinateAssignment()
    }
  }

  private static func groupPlacementAlgorithm(
    for id: PolicyCanvasAlgorithmID
  ) -> any PolicyCanvasGroupPlacementAlgorithm {
    switch id {
    case PolicyCanvasAlgorithmDefaults.harnessGroupFramePacking:
      PolicyCanvasHarnessGroupFramePacking()
    case PolicyCanvasAlgorithmDefaults.layeredClusterFramePacking:
      PolicyCanvasLayeredClusterFramePacking()
    default:
      PolicyCanvasTightBoundingBoxGroupFrames()
    }
  }

  private static func layoutPostProcessingAlgorithm(
    for id: PolicyCanvasAlgorithmID
  ) -> any PolicyCanvasLayoutPostProcessingAlgorithm {
    switch id {
    case PolicyCanvasAlgorithmDefaults.terminalCombAndSingleFedAlignment:
      PolicyCanvasTerminalCombAndSingleFedAlignment()
    default:
      PolicyCanvasNoOpLayoutPostProcessing()
    }
  }

  private static func metricsAlgorithm(
    for id: PolicyCanvasAlgorithmID
  ) -> any PolicyCanvasMetricsAlgorithm {
    switch id {
    case PolicyCanvasAlgorithmDefaults.sugiyamaCrossingMetrics:
      PolicyCanvasSugiyamaCrossingMetrics()
    default:
      PolicyCanvasHarnessReadabilityMetricsAlgorithm()
    }
  }

  private static func portMarkerPlacementAlgorithm(
    for id: PolicyCanvasAlgorithmID
  ) -> any PolicyCanvasPortMarkerPlacementAlgorithm {
    switch id {
    case PolicyCanvasAlgorithmDefaults.noOpPortMarkers:
      PolicyCanvasNoOpPortMarkerPlacement()
    default:
      PolicyCanvasCollisionDerivedPortMarkerPlacement()
    }
  }

  private static func edgeRouterAlgorithm(
    for id: PolicyCanvasAlgorithmID
  ) -> any PolicyCanvasEdgeRouter {
    switch id {
    case PolicyCanvasAlgorithmDefaults.orthogonalVisibilityAStar:
      PolicyCanvasOrthogonalVisibilityGraphAStarRouter()
    default:
      PolicyCanvasMemoizedRouter(inner: PolicyCanvasVisibilityRouter())
    }
  }

  private static func routeSelectionAlgorithm(
    for id: PolicyCanvasAlgorithmID
  ) -> any PolicyCanvasRouteSelectionAlgorithm {
    switch id {
    case PolicyCanvasAlgorithmDefaults.firstFeasibleRouteSelection:
      PolicyCanvasFirstFeasibleRouteSelection()
    default:
      PolicyCanvasClearanceScoredRouteSelection()
    }
  }

  private static func routePostProcessingAlgorithm(
    for id: PolicyCanvasAlgorithmID
  ) -> any PolicyCanvasRoutePostProcessingAlgorithm {
    switch id {
    case PolicyCanvasAlgorithmDefaults.collinearRouteCompression:
      PolicyCanvasCollinearRouteCompression()
    default:
      PolicyCanvasVerticalDeclutterFanInNesting()
    }
  }

  private static func labelPlacementAlgorithm(
    for id: PolicyCanvasAlgorithmID
  ) -> any PolicyCanvasEdgeLabelPlacementAlgorithm {
    switch id {
    case PolicyCanvasAlgorithmDefaults.polylineMidpointLabelPlacement:
      PolicyCanvasPolylineMidpointLabelPlacement()
    default:
      PolicyCanvasObstacleAwareGreedyLabelPlacement()
    }
  }
}
