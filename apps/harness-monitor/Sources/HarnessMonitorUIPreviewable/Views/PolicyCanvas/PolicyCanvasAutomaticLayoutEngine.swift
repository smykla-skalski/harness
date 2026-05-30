import Foundation
import SwiftUI

// `PolicyCanvasAutomaticLayoutMode` and `PolicyCanvasOrderSeedStrategy` live in
// `PolicyCanvasAutomaticLayoutMode.swift`.

struct PolicyCanvasLayoutGraph: Sendable {
  var nodes: [PolicyCanvasLayoutNode]
  var edges: [PolicyCanvasLayoutEdge]
  var groups: [PolicyCanvasLayoutGroup]
}

struct PolicyCanvasLayoutNode: Identifiable, Sendable {
  let id: String
  let groupID: String?
  let originalIndex: Int
  let currentPosition: CGPoint
  let anchor: PolicyCanvasLayoutAnchor?
}

struct PolicyCanvasLayoutAnchor: Equatable, Sendable {
  let position: CGPoint
}

struct PolicyCanvasLayoutEdge: Identifiable, Sendable {
  let id: String
  let sourceNodeID: String
  let targetNodeID: String
  let label: String

  init(
    id: String,
    sourceNodeID: String,
    targetNodeID: String,
    label: String = ""
  ) {
    self.id = id
    self.sourceNodeID = sourceNodeID
    self.targetNodeID = targetNodeID
    self.label = label
  }
}

struct PolicyCanvasLayoutGroup: Identifiable, Sendable {
  let id: String
  let originalIndex: Int
  let memberNodeIDs: [String]
}

struct PolicyCanvasLayoutMetrics: Equatable, Sendable {
  let macroLayerCount: Int
  let crossGroupOrderViolations: Int
  let anchoredNodeCount: Int
  let edgeCrossingCount: Int
  let flowDirectionViolationCount: Int
  let averageEdgeLength: Double
  let edgeLengthVariance: Double
  let readabilityScore: Double
}

struct PolicyCanvasRouteCorridorKey: Equatable, Hashable, Sendable {
  let sourceScopeID: String
  let targetScopeID: String
  let targetNodeID: String
  let label: String
  let laneIndex: Int
}

struct PolicyCanvasEdgeCorridorHint: Equatable, Hashable, Sendable {
  let key: PolicyCanvasRouteCorridorKey
  let horizontalLaneY: CGFloat
  let verticalLaneX: CGFloat?
  let bundleOrdinal: Int
  let bundleSize: Int

  init(
    key: PolicyCanvasRouteCorridorKey,
    horizontalLaneY: CGFloat,
    verticalLaneX: CGFloat?,
    bundleOrdinal: Int = 0,
    bundleSize: Int = 1
  ) {
    self.key = key
    self.horizontalLaneY = horizontalLaneY
    self.verticalLaneX = verticalLaneX
    self.bundleOrdinal = bundleOrdinal
    self.bundleSize = bundleSize
  }
}

struct PolicyCanvasLayoutRoutingHints: Equatable, Hashable, Sendable {
  let edgeHints: [String: PolicyCanvasEdgeCorridorHint]

  static let empty = Self(edgeHints: [:])

  var isEmpty: Bool {
    edgeHints.isEmpty
  }

  func edgeHint(for edgeID: String) -> PolicyCanvasEdgeCorridorHint? {
    edgeHints[edgeID]
  }

  func offsetBy(dx: CGFloat, dy: CGFloat) -> Self {
    guard dx != 0 || dy != 0 else {
      return self
    }
    return Self(
      edgeHints: edgeHints.mapValues { hint in
        PolicyCanvasEdgeCorridorHint(
          key: hint.key,
          horizontalLaneY: hint.horizontalLaneY + dy,
          verticalLaneX: hint.verticalLaneX.map { $0 + dx }
        )
      }
    )
  }
}

struct PolicyCanvasLayoutResult: Sendable {
  let nodePositions: [String: CGPoint]
  let groupFrames: [String: CGRect]
  let autoPlacedNodeIDs: Set<String>
  let metrics: PolicyCanvasLayoutMetrics
  let routingHints: PolicyCanvasLayoutRoutingHints?
}

struct PolicyCanvasLayoutConfiguration: Sendable {
  let interGroupSpacing: CGFloat
  let columnSpacing: CGFloat
  let rowSpacing: CGFloat
  let targetGroupAspectRatio: CGFloat
  let sweepPassCount: Int

  var columnStep: CGFloat {
    PolicyCanvasLayout.nodeSize.width + columnSpacing
  }

  var rowStep: CGFloat {
    PolicyCanvasLayout.nodeSize.height + rowSpacing
  }

  static let layeredDefault = Self(
    interGroupSpacing: 120,
    columnSpacing: 140,
    rowSpacing: 140,
    targetGroupAspectRatio: 2,
    sweepPassCount: 12
  )
}

protocol PolicyCanvasLayoutEngine {
  func layout(
    graph: PolicyCanvasLayoutGraph,
    configuration: PolicyCanvasLayoutConfiguration
  ) -> PolicyCanvasLayoutResult?
}

struct PolicyCanvasLayeredOrderingItem: Identifiable, Equatable {
  let id: String
  let realNodeID: String?
  let rank: Int

  var isDummy: Bool {
    realNodeID == nil
  }
}

struct PolicyCanvasLayeredOrderingGraph {
  let itemsByID: [String: PolicyCanvasLayeredOrderingItem]
  let layers: [[String]]
  let incoming: [String: [String]]
  let outgoing: [String: [String]]
}

struct PolicyCanvasLayeredLayoutEngine: PolicyCanvasLayoutEngine {
  let mode: PolicyCanvasAutomaticLayoutMode

  init(mode: PolicyCanvasAutomaticLayoutMode = .initialLoad) {
    self.mode = mode
  }

  func layout(
    graph: PolicyCanvasLayoutGraph,
    configuration: PolicyCanvasLayoutConfiguration = .layeredDefault
  ) -> PolicyCanvasLayoutResult? {
    guard !graph.nodes.isEmpty else {
      return nil
    }

    let normalizedGroups = normalizedGroups(for: graph)
    let nodesByID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
    let layoutGroupIDByNodeID = Dictionary(
      uniqueKeysWithValues: normalizedGroups.flatMap { group in
        group.nodeIDs.map { ($0, group.layoutID) }
      }
    )
    let anchoredNodeIDs = Set(
      graph.nodes.compactMap { node in
        node.anchor == nil ? nil : node.id
      })
    let acyclicNodeEdges = policyCanvasAcyclicEdges(
      ids: graph.nodes.map(\.id),
      originalOrder: Dictionary(
        uniqueKeysWithValues: graph.nodes.map { ($0.id, $0.originalIndex) }),
      edges: graph.edges
    )
    let inputs = PolicyCanvasLayeredLayoutInputs(
      graph: graph,
      normalizedGroups: normalizedGroups,
      layoutGroupIDByNodeID: layoutGroupIDByNodeID,
      groupRanks: groupRanks(
        for: normalizedGroups,
        edges: acyclicNodeEdges,
        layoutGroupIDByNodeID: layoutGroupIDByNodeID
      ),
      internalRanks: internalRanks(
        for: normalizedGroups,
        edges: acyclicNodeEdges,
        layoutGroupIDByNodeID: layoutGroupIDByNodeID
      ),
      acyclicNodeEdges: acyclicNodeEdges,
      configuration: configuration
    )

    if anchoredNodeIDs.isEmpty {
      return unconstrainedLayeredLayout(inputs: inputs)
    }
    return anchoredLayeredLayout(
      inputs: inputs,
      anchoredNodeIDs: anchoredNodeIDs,
      nodesByID: nodesByID
    )
  }
}

struct PolicyCanvasNormalizedLayoutGroup {
  let layoutID: String
  let actualGroupID: String?
  let originalIndex: Int
  var nodeIDs: [String]
}

struct PolicyCanvasLayeredLayoutInputs {
  let graph: PolicyCanvasLayoutGraph
  let normalizedGroups: [PolicyCanvasNormalizedLayoutGroup]
  let layoutGroupIDByNodeID: [String: String]
  let groupRanks: [String: Int]
  let internalRanks: [String: Int]
  let acyclicNodeEdges: [PolicyCanvasLayoutEdge]
  let configuration: PolicyCanvasLayoutConfiguration
}

struct PolicyCanvasUnconstrainedPlacement {
  var nodePositions: [String: CGPoint] = [:]
  var groupFrames: [String: CGRect] = [:]
  var groupFramesByLayoutID: [String: CGRect] = [:]
  var autoPlacedNodeIDs: Set<String> = []
  var nextAutoGroupMinX: CGFloat = 0
}

struct PolicyCanvasMemberOrderingTables {
  let internalRanks: [String: Int]
  let placedNeighborCenterY: [String: CGFloat]
  let itemCenterY: [String: CGFloat]
  let orderHints: [String: Double]
}

struct PolicyCanvasOrderSeed {
  let priority: Int
  let y: CGFloat
  let x: CGFloat
}

struct PolicyCanvasBarycenterContext {
  let graph: PolicyCanvasLayoutGraph
  let layoutGroupIDByNodeID: [String: String]
  let preferIncomingNeighbors: Bool
}

struct PolicyCanvasVerticalBalanceContext {
  let graph: PolicyCanvasLayoutGraph
  let layoutGroupIDByNodeID: [String: String]
  let anchoredGroupIDs: Set<String>
  let configuration: PolicyCanvasLayoutConfiguration
}

struct PolicyCanvasLayerTransposeContext {
  let graph: PolicyCanvasLayeredOrderingGraph
  let movingRank: Int
  let fixedRank: Int
  let forward: Bool
}

struct PolicyCanvasAnchoredPlacement {
  var nodePositions: [String: CGPoint] = [:]
  var groupFrames: [String: CGRect] = [:]
  var groupFramesByLayoutID: [String: CGRect] = [:]
  var autoPlacedNodeIDs: Set<String> = []
  var anchoredGroupIDs: Set<String> = []
  var nextAutoGroupMinX: CGFloat = 0
}

struct PolicyCanvasAnchoredGroupContext {
  let nodesByID: [String: PolicyCanvasLayoutNode]
  let anchoredNodeIDs: Set<String>
  let internalRanks: [String: Int]
  let orderHints: [String: Double]
  let configuration: PolicyCanvasLayoutConfiguration
}
