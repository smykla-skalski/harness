import CoreGraphics
import Foundation

struct PolicyCanvasCycleBreakingInput: Sendable {
  let nodeIDs: [String]
  let originalOrder: [String: Int]
  let edges: [PolicyCanvasLayoutEdge]
}

struct PolicyCanvasRankAssignmentInput: Sendable {
  let graph: PolicyCanvasLayoutGraph
  let nodeIDs: [String]
  let originalOrder: [String: Int]
  let edges: [PolicyCanvasLayoutEdge]
  let mode: PolicyCanvasAutomaticLayoutMode
}

struct PolicyCanvasRankAssignmentOutput: Sendable {
  let nodeRanks: [String: Int]
  let scopeRanks: [String: Int]
  let layoutGroupIDByNodeID: [String: String]
  let normalizedGroups: [PolicyCanvasNormalizedLayoutGroup]
  let internalRanks: [String: Int]
  let initialOrders: [String: Double]
  let acyclicEdges: [PolicyCanvasLayoutEdge]
}

struct PolicyCanvasLongEdgeNormalizationInput: Sendable {
  let nodeIDs: [String]
  let ranks: [String: Int]
  let edges: [PolicyCanvasLayoutEdge]
  let initialOrders: [String: Double]
}

struct PolicyCanvasLayerOrderingInput: Sendable {
  let graph: PolicyCanvasLayeredOrderingGraph
  let maxPasses: Int
}

struct PolicyCanvasCoordinateAssignmentInput: Sendable {
  let layers: [[String]]
  let graph: PolicyCanvasLayeredOrderingGraph
  let configuration: PolicyCanvasLayoutConfiguration
}

struct PolicyCanvasCoordinateAssignmentOutput: Sendable {
  let itemCenterY: [String: CGFloat]
}

struct PolicyCanvasGroupPlacementInput: Sendable {
  let graph: PolicyCanvasLayoutGraph
  let mode: PolicyCanvasAutomaticLayoutMode
  let rankAssignment: PolicyCanvasRankAssignmentOutput
  let itemCenterY: [String: CGFloat]
  let orderHints: [String: Double]
  let fallbackNodePositions: [String: CGPoint]
  let configuration: PolicyCanvasLayoutConfiguration
}

struct PolicyCanvasGroupPlacementOutput: Sendable {
  let nodePositions: [String: CGPoint]
  let groupFrames: [String: CGRect]
  let groupFramesByLayoutID: [String: CGRect]
  let autoPlacedNodeIDs: Set<String>
}

struct PolicyCanvasLayoutPostProcessingInput: Sendable {
  let graph: PolicyCanvasLayoutGraph
  let rankAssignment: PolicyCanvasRankAssignmentOutput
  let nodePositions: [String: CGPoint]
  let groupFrames: [String: CGRect]
  let groupFramesByLayoutID: [String: CGRect]
}

struct PolicyCanvasLayoutPostProcessingOutput: Sendable {
  let nodePositions: [String: CGPoint]
  let groupFrames: [String: CGRect]
  let groupFramesByLayoutID: [String: CGRect]
}

struct PolicyCanvasMetricsInput: Sendable {
  let graph: PolicyCanvasLayoutGraph
  let nodePositions: [String: CGPoint]
  let ranks: [String: Int]
  let layoutGroupIDByNodeID: [String: String]
}

protocol PolicyCanvasCycleBreakingAlgorithm: Sendable {
  func breakCycles(input: PolicyCanvasCycleBreakingInput) -> [PolicyCanvasLayoutEdge]
}

protocol PolicyCanvasRankAssignmentAlgorithm: Sendable {
  func assignRanks(input: PolicyCanvasRankAssignmentInput) -> PolicyCanvasRankAssignmentOutput
}

protocol PolicyCanvasLongEdgeNormalizationAlgorithm: Sendable {
  func normalize(input: PolicyCanvasLongEdgeNormalizationInput) -> PolicyCanvasLayeredOrderingGraph
}

protocol PolicyCanvasLayerOrderingAlgorithm: Sendable {
  func orderLayers(input: PolicyCanvasLayerOrderingInput) -> [[String]]
}

protocol PolicyCanvasCoordinateAssignmentAlgorithm: Sendable {
  func assignCoordinates(
    input: PolicyCanvasCoordinateAssignmentInput
  ) -> PolicyCanvasCoordinateAssignmentOutput
}

protocol PolicyCanvasGroupPlacementAlgorithm: Sendable {
  func placeGroups(input: PolicyCanvasGroupPlacementInput) -> PolicyCanvasGroupPlacementOutput
}

protocol PolicyCanvasLayoutPostProcessingAlgorithm: Sendable {
  func processLayout(
    input: PolicyCanvasLayoutPostProcessingInput
  ) -> PolicyCanvasLayoutPostProcessingOutput
}

protocol PolicyCanvasMetricsAlgorithm: Sendable {
  func measure(input: PolicyCanvasMetricsInput) -> PolicyCanvasLayoutMetrics
}
