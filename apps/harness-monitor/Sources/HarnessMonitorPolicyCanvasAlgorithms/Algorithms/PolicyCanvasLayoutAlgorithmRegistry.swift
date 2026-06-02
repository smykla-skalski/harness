import Foundation

struct PolicyCanvasLayoutStageAlgorithmSet: Sendable {
  let cycleBreaking: any PolicyCanvasCycleBreakingAlgorithm
  let rankAssignment: any PolicyCanvasRankAssignmentAlgorithm
  let longEdgeNormalization: any PolicyCanvasLongEdgeNormalizationAlgorithm
  let layerOrdering: any PolicyCanvasLayerOrderingAlgorithm
  let coordinateAssignment: any PolicyCanvasCoordinateAssignmentAlgorithm
  let groupPlacement: any PolicyCanvasGroupPlacementAlgorithm
  let layoutPostProcessing: any PolicyCanvasLayoutPostProcessingAlgorithm
  let metrics: any PolicyCanvasMetricsAlgorithm
}

enum PolicyCanvasLayoutAlgorithmRegistry {
  static func isHarnessCurrentLayout(_ selection: PolicyCanvasAlgorithmSelection) -> Bool {
    PolicyCanvasAlgorithmDefaults.layoutStages.allSatisfy { stage in
      selection.algorithmID(for: stage)
        == PolicyCanvasAlgorithmDefaults.harnessCurrentID(for: stage)
    }
  }

  static func layoutAlgorithms(
    for selection: PolicyCanvasAlgorithmSelection
  ) -> PolicyCanvasLayoutStageAlgorithmSet {
    PolicyCanvasLayoutStageAlgorithmSet(
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
}
