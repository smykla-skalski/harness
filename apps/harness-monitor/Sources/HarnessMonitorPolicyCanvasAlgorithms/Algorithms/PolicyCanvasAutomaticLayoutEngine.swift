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

public struct PolicyCanvasLayoutMetrics: Equatable, Sendable {
  public let macroLayerCount: Int
  public let crossGroupOrderViolations: Int
  public let anchoredNodeCount: Int
  public let edgeCrossingCount: Int
  public let flowDirectionViolationCount: Int
  public let averageEdgeLength: Double
  public let edgeLengthVariance: Double
  public let readabilityScore: Double
}

public struct PolicyCanvasRouteCorridorKey: Equatable, Hashable, Sendable {
  public let sourceScopeID: String
  public let targetScopeID: String
  public let targetNodeID: String
  public let label: String
  public let laneIndex: Int

  public init(
    sourceScopeID: String,
    targetScopeID: String,
    targetNodeID: String,
    label: String,
    laneIndex: Int
  ) {
    self.sourceScopeID = sourceScopeID
    self.targetScopeID = targetScopeID
    self.targetNodeID = targetNodeID
    self.label = label
    self.laneIndex = laneIndex
  }
}

public struct PolicyCanvasEdgeCorridorHint: Equatable, Hashable, Sendable {
  public let key: PolicyCanvasRouteCorridorKey
  public let horizontalLaneY: CGFloat
  public let verticalLaneX: CGFloat?
  public let bundleOrdinal: Int
  public let bundleSize: Int

  public init(
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

public struct PolicyCanvasLayoutRoutingHints: Equatable, Hashable, Sendable {
  public let edgeHints: [String: PolicyCanvasEdgeCorridorHint]

  public static let empty = Self(edgeHints: [:])

  public var isEmpty: Bool {
    edgeHints.isEmpty
  }

  public func edgeHint(for edgeID: String) -> PolicyCanvasEdgeCorridorHint? {
    edgeHints[edgeID]
  }

  public func offsetBy(dx: CGFloat, dy: CGFloat) -> Self {
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

public struct PolicyCanvasLayoutResult: Sendable {
  public let nodePositions: [String: CGPoint]
  public let groupFrames: [String: CGRect]
  public let autoPlacedNodeIDs: Set<String>
  public let metrics: PolicyCanvasLayoutMetrics
  public let routingHints: PolicyCanvasLayoutRoutingHints?
}

public struct PolicyCanvasLayoutConfiguration: Sendable {
  public let interGroupSpacing: CGFloat
  public let columnSpacing: CGFloat
  public let rowSpacing: CGFloat
  public let targetGroupAspectRatio: CGFloat
  public let sweepPassCount: Int

  public var columnStep: CGFloat {
    PolicyCanvasLayout.nodeSize.width + columnSpacing
  }

  public var rowStep: CGFloat {
    PolicyCanvasLayout.nodeSize.height + rowSpacing
  }

  public static let layeredDefault = Self(
    interGroupSpacing: 120,
    columnSpacing: 140,
    rowSpacing: 140,
    targetGroupAspectRatio: 2,
    sweepPassCount: 12
  )

  public init(
    interGroupSpacing: CGFloat,
    columnSpacing: CGFloat,
    rowSpacing: CGFloat,
    targetGroupAspectRatio: CGFloat,
    sweepPassCount: Int
  ) {
    self.interGroupSpacing = interGroupSpacing
    self.columnSpacing = columnSpacing
    self.rowSpacing = rowSpacing
    self.targetGroupAspectRatio = targetGroupAspectRatio
    self.sweepPassCount = sweepPassCount
  }
}

protocol PolicyCanvasLayoutEngine {
  func layout(
    graph: PolicyCanvasLayoutGraph,
    configuration: PolicyCanvasLayoutConfiguration
  ) -> PolicyCanvasLayoutResult?
}

struct PolicyCanvasLayeredOrderingItem: Identifiable, Equatable, Sendable {
  let id: String
  let realNodeID: String?
  let rank: Int

  var isDummy: Bool {
    realNodeID == nil
  }
}

struct PolicyCanvasLayeredOrderingGraph: Sendable {
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

struct PolicyCanvasNormalizedLayoutGroup: Sendable {
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
