import Foundation

public struct PolicyCanvasAlgorithmID: RawRepresentable, Hashable, Identifiable, Sendable {
  public let rawValue: String

  public var id: String { rawValue }

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }
}

public enum PolicyCanvasAlgorithmStage: String, CaseIterable, Identifiable, Sendable {
  case cycleBreaking
  case rankAssignment
  case longEdgeNormalization
  case layerOrdering
  case coordinateAssignment
  case groupPlacement
  case layoutPostProcessing
  case portMarkerPlacement
  case edgeRouting
  case routeSelection
  case routePostProcessing
  case labelPlacement
  case metrics

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .cycleBreaking: "Cycle breaking"
    case .rankAssignment: "Rank assignment"
    case .longEdgeNormalization: "Long-edge normalization"
    case .layerOrdering: "Layer ordering"
    case .coordinateAssignment: "Coordinate assignment"
    case .groupPlacement: "Group placement"
    case .layoutPostProcessing: "Layout post-processing"
    case .portMarkerPlacement: "Port markers"
    case .edgeRouting: "Edge routing"
    case .routeSelection: "Route selection"
    case .routePostProcessing: "Route post-processing"
    case .labelPlacement: "Label placement"
    case .metrics: "Metrics"
    }
  }
}

public struct PolicyCanvasAlgorithmSelection: Equatable, Hashable, Sendable {
  public var selectedAlgorithmIDs: [PolicyCanvasAlgorithmStage: PolicyCanvasAlgorithmID]

  public init(selectedAlgorithmIDs: [PolicyCanvasAlgorithmStage: PolicyCanvasAlgorithmID] = [:]) {
    self.selectedAlgorithmIDs = selectedAlgorithmIDs
  }

  public func algorithmID(for stage: PolicyCanvasAlgorithmStage) -> PolicyCanvasAlgorithmID {
    selectedAlgorithmIDs[stage] ?? PolicyCanvasAlgorithmDefaults.harnessCurrentID(for: stage)
  }

  public func replacing(
    stage: PolicyCanvasAlgorithmStage,
    with id: PolicyCanvasAlgorithmID
  ) -> Self {
    var next = self
    next.selectedAlgorithmIDs[stage] = id
    return next
  }

  public var layoutCacheIdentity: String {
    Self.cacheIdentity(for: PolicyCanvasAlgorithmDefaults.layoutStages, in: self)
  }

  public var routingCacheIdentity: String {
    Self.cacheIdentity(for: PolicyCanvasAlgorithmDefaults.routingStages, in: self)
  }

  public var cacheIdentity: String {
    Self.cacheIdentity(for: PolicyCanvasAlgorithmStage.allCases, in: self)
  }

  public static let referencePure = Self(
    selectedAlgorithmIDs: PolicyCanvasAlgorithmDefaults.referencePureIDs
  )

  /// The production routing pipeline (and the default fill): padded
  /// visibility-graph A*, first-feasible selection, crossing-aware orthogonal
  /// nudging, and route-terminal port markers. Automatic placement is handled
  /// by ELK and no longer varies by this selection.
  public static let referenceRouting = Self(
    selectedAlgorithmIDs: PolicyCanvasAlgorithmDefaults.harnessCurrentIDs
  )

  private static func cacheIdentity(
    for stages: [PolicyCanvasAlgorithmStage],
    in selection: Self
  ) -> String {
    stages.map { stage in
      "\(stage.rawValue)=\(selection.algorithmID(for: stage).rawValue)"
    }
    .joined(separator: "|")
  }
}

enum PolicyCanvasAlgorithmDefaults {
  static let depthFirstBackEdgeReversal = PolicyCanvasAlgorithmID(
    "depth-first-back-edge-reversal"
  )
  static let greedyFeedbackArcReversal = PolicyCanvasAlgorithmID(
    "greedy-feedback-arc-reversal"
  )
  static let harnessGroupAwareLongestPath = PolicyCanvasAlgorithmID(
    "harness-group-aware-longest-path-layering"
  )
  static let longestPathLayering = PolicyCanvasAlgorithmID("longest-path-layering")
  static let interpolatedDummyChain = PolicyCanvasAlgorithmID(
    "interpolated-dummy-chain-normalization"
  )
  static let unitDummyChain = PolicyCanvasAlgorithmID("unit-dummy-chain-normalization")
  static let seededBarycenterTranspose = PolicyCanvasAlgorithmID(
    "seeded-barycenter-transpose-crossing-reduction"
  )
  static let barycenterTransposeCrossingReduction = PolicyCanvasAlgorithmID(
    "barycenter-transpose-crossing-reduction"
  )
  static let barycenterCrossingReduction = PolicyCanvasAlgorithmID(
    "barycenter-crossing-reduction"
  )
  static let brandesKopfCoordinateAssignment = PolicyCanvasAlgorithmID(
    "brandes-kopf-coordinate-assignment"
  )
  static let layeredGridCoordinateAssignment = PolicyCanvasAlgorithmID(
    "layered-grid-coordinate-assignment"
  )
  static let harnessGroupFramePacking = PolicyCanvasAlgorithmID("harness-group-frame-packing")
  static let layeredClusterFramePacking = PolicyCanvasAlgorithmID(
    "layered-cluster-frame-packing"
  )
  static let tightBoundingBoxGroupFrames = PolicyCanvasAlgorithmID(
    "tight-bounding-box-group-frames"
  )
  static let terminalCombAndSingleFedAlignment = PolicyCanvasAlgorithmID(
    "terminal-comb-and-single-fed-alignment"
  )
  static let noOpLayoutPostProcessing = PolicyCanvasAlgorithmID(
    "no-op-layout-post-processing"
  )
  static let routeTerminalPortMarkers = PolicyCanvasAlgorithmID(
    "route-terminal-port-marker-placement"
  )
  static let noOpPortMarkers = PolicyCanvasAlgorithmID("no-op-port-marker-placement")
  static let paddedOrthogonalVisibilityAStar = PolicyCanvasAlgorithmID(
    "padded-orthogonal-visibility-graph-a-star"
  )
  static let orthogonalVisibilityAStar = PolicyCanvasAlgorithmID(
    "orthogonal-visibility-graph-a-star"
  )
  static let firstFeasibleRouteSelection = PolicyCanvasAlgorithmID(
    "first-feasible-route-selection"
  )
  static let collinearRouteCompression = PolicyCanvasAlgorithmID(
    "collinear-route-compression"
  )
  static let orthogonalNudgedRouteProcessing = PolicyCanvasAlgorithmID(
    "orthogonal-nudged-route-processing"
  )
  static let obstacleAwareGreedyLabelPlacement = PolicyCanvasAlgorithmID(
    "obstacle-aware-greedy-label-placement"
  )
  static let polylineMidpointLabelPlacement = PolicyCanvasAlgorithmID(
    "polyline-midpoint-label-placement"
  )
  static let harnessReadabilityMetrics = PolicyCanvasAlgorithmID("harness-readability-metrics")
  static let sugiyamaCrossingMetrics = PolicyCanvasAlgorithmID("sugiyama-crossing-metrics")

  static let layoutStages: [PolicyCanvasAlgorithmStage] = [
    .cycleBreaking,
    .rankAssignment,
    .longEdgeNormalization,
    .layerOrdering,
    .coordinateAssignment,
    .groupPlacement,
    .layoutPostProcessing,
    .metrics,
  ]

  static let routingStages: [PolicyCanvasAlgorithmStage] = [
    .portMarkerPlacement,
    .edgeRouting,
    .routeSelection,
    .routePostProcessing,
    .labelPlacement,
  ]

  /// The production routing pipeline and the fill used for any unspecified
  /// stage. Layout-stage IDs remain only for compatibility with focused
  /// component tests; automatic placement is ELK-only.
  static let harnessCurrentIDs: [PolicyCanvasAlgorithmStage: PolicyCanvasAlgorithmID] = [
    .cycleBreaking: depthFirstBackEdgeReversal,
    .rankAssignment: harnessGroupAwareLongestPath,
    .longEdgeNormalization: interpolatedDummyChain,
    .layerOrdering: seededBarycenterTranspose,
    .coordinateAssignment: brandesKopfCoordinateAssignment,
    .groupPlacement: harnessGroupFramePacking,
    .layoutPostProcessing: terminalCombAndSingleFedAlignment,
    .portMarkerPlacement: routeTerminalPortMarkers,
    .edgeRouting: paddedOrthogonalVisibilityAStar,
    .routeSelection: firstFeasibleRouteSelection,
    .routePostProcessing: orthogonalNudgedRouteProcessing,
    .labelPlacement: obstacleAwareGreedyLabelPlacement,
    .metrics: harnessReadabilityMetrics,
  ]

  static let referencePureIDs: [PolicyCanvasAlgorithmStage: PolicyCanvasAlgorithmID] = [
    .cycleBreaking: greedyFeedbackArcReversal,
    .rankAssignment: longestPathLayering,
    .longEdgeNormalization: unitDummyChain,
    .layerOrdering: barycenterTransposeCrossingReduction,
    .coordinateAssignment: brandesKopfCoordinateAssignment,
    .groupPlacement: layeredClusterFramePacking,
    .layoutPostProcessing: noOpLayoutPostProcessing,
    .portMarkerPlacement: routeTerminalPortMarkers,
    .edgeRouting: orthogonalVisibilityAStar,
    .routeSelection: firstFeasibleRouteSelection,
    .routePostProcessing: collinearRouteCompression,
    .labelPlacement: polylineMidpointLabelPlacement,
    .metrics: sugiyamaCrossingMetrics,
  ]

  static func harnessCurrentID(for stage: PolicyCanvasAlgorithmStage) -> PolicyCanvasAlgorithmID {
    guard let id = harnessCurrentIDs[stage] else {
      preconditionFailure("Missing harness-current policy canvas algorithm for \(stage)")
    }
    return id
  }

}
