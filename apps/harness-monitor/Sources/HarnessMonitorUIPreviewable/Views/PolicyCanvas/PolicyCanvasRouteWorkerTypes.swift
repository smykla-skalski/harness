import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

struct PolicyCanvasRouteWorkerKey: Equatable {
  let graphGeneration: UInt64
  let nodeCount: Int
  let groupCount: Int
  let edgeCount: Int
  let fontScale: CGFloat
  let routingHints: PolicyCanvasLayoutRoutingHints?
  let algorithmSelection: PolicyCanvasAlgorithmSelection

  init(
    graphGeneration: UInt64,
    nodeCount: Int,
    groupCount: Int,
    edgeCount: Int,
    fontScale: CGFloat,
    routingHints: PolicyCanvasLayoutRoutingHints?,
    algorithmSelection: PolicyCanvasAlgorithmSelection = .referenceRouting
  ) {
    self.graphGeneration = graphGeneration
    self.nodeCount = nodeCount
    self.groupCount = groupCount
    self.edgeCount = edgeCount
    self.fontScale = fontScale
    self.routingHints = routingHints
    self.algorithmSelection = algorithmSelection
  }
}

struct PolicyCanvasRouteWorkerOutput: Equatable, Sendable {
  let signature: PolicyCanvasRouteWorkerOutputSignature
  let routes: [String: PolicyCanvasEdgeRoute]
  let labelPositions: [String: CGPoint]
  let portVisibility: PolicyCanvasPortVisibilityMap
  let portMarkerLayout: PolicyCanvasPortMarkerLayout
  let visibleBounds: CGRect
  let contentSize: CGSize
  let accessibilityEdgeLabelsByID: [String: String]
  let accessibilityNodeEntries: [PolicyCanvasAccessibilityNodeEntry]
  let accessibilityEdgeEntries: [PolicyCanvasAccessibilityEdgeEntry]
  let nodeAccessibilityValuesByID: [String: String]
  let connectTargetsByNodeID: [String: [PolicyCanvasAccessibilityConnectTarget]]

  static let empty = Self(
    signature: .empty,
    routes: [:],
    labelPositions: [:],
    portVisibility: [:],
    portMarkerLayout: .empty,
    visibleBounds: CGRect(origin: .zero, size: PolicyCanvasLayout.minimumCanvasSize),
    contentSize: PolicyCanvasLayout.minimumCanvasSize,
    accessibilityEdgeLabelsByID: [:],
    accessibilityNodeEntries: [],
    accessibilityEdgeEntries: [],
    nodeAccessibilityValuesByID: [:],
    connectTargetsByNodeID: [:]
  )

  static func fallback(for input: PolicyCanvasRouteWorkerInput) -> Self {
    let prepared = PolicyCanvasPreparedRouteInput(input: input)
    let nodeIndex = prepared.nodeIndex
    let routes: [String: PolicyCanvasEdgeRoute] = prepared.fallbackRoutes(nodeIndex: nodeIndex)
    let visibleBounds = prepared.visibleBounds(routes: routes, labelPositions: [:])
    let contentSize = policyCanvasVisibleContentSize(visibleBounds: visibleBounds)
    return Self(
      signature: PolicyCanvasRouteWorkerOutputSignature(
        routes: routes,
        labelPositions: [:],
        portVisibility: [:],
        portMarkerLayout: .empty,
        visibleBounds: visibleBounds,
        contentSize: contentSize,
        accessibilityNodeEntries: [],
        accessibilityEdgeEntries: [],
        nodeAccessibilityValuesByID: [:],
        connectTargetsByNodeID: [:]
      ),
      routes: routes,
      labelPositions: [:],
      portVisibility: [:],
      portMarkerLayout: .empty,
      visibleBounds: visibleBounds,
      contentSize: contentSize,
      accessibilityEdgeLabelsByID: [:],
      accessibilityNodeEntries: [],
      accessibilityEdgeEntries: [],
      nodeAccessibilityValuesByID: [:],
      connectTargetsByNodeID: [:]
    )
  }

  init(
    signature: PolicyCanvasRouteWorkerOutputSignature,
    routes: [String: PolicyCanvasEdgeRoute],
    labelPositions: [String: CGPoint],
    portVisibility: PolicyCanvasPortVisibilityMap,
    portMarkerLayout: PolicyCanvasPortMarkerLayout,
    visibleBounds: CGRect,
    contentSize: CGSize,
    accessibilityEdgeLabelsByID: [String: String],
    accessibilityNodeEntries: [PolicyCanvasAccessibilityNodeEntry],
    accessibilityEdgeEntries: [PolicyCanvasAccessibilityEdgeEntry],
    nodeAccessibilityValuesByID: [String: String],
    connectTargetsByNodeID: [String: [PolicyCanvasAccessibilityConnectTarget]]
  ) {
    self.signature = signature
    self.routes = routes
    self.labelPositions = labelPositions
    self.portVisibility = portVisibility
    self.portMarkerLayout = portMarkerLayout
    self.visibleBounds = visibleBounds
    self.contentSize = contentSize
    self.accessibilityEdgeLabelsByID = accessibilityEdgeLabelsByID
    self.accessibilityNodeEntries = accessibilityNodeEntries
    self.accessibilityEdgeEntries = accessibilityEdgeEntries
    self.nodeAccessibilityValuesByID = nodeAccessibilityValuesByID
    self.connectTargetsByNodeID = connectTargetsByNodeID
  }

  init(
    routes: [String: PolicyCanvasEdgeRoute],
    labelPositions: [String: CGPoint],
    portVisibility: PolicyCanvasPortVisibilityMap,
    portMarkerLayout: PolicyCanvasPortMarkerLayout,
    visibleBounds: CGRect,
    contentSize: CGSize,
    accessibilityEdgeLabelsByID: [String: String],
    accessibilityNodeEntries: [PolicyCanvasAccessibilityNodeEntry],
    accessibilityEdgeEntries: [PolicyCanvasAccessibilityEdgeEntry],
    nodeAccessibilityValuesByID: [String: String],
    connectTargetsByNodeID: [String: [PolicyCanvasAccessibilityConnectTarget]]
  ) {
    self.init(
      signature: PolicyCanvasRouteWorkerOutputSignature(
        routes: routes,
        labelPositions: labelPositions,
        portVisibility: portVisibility,
        portMarkerLayout: portMarkerLayout,
        visibleBounds: visibleBounds,
        contentSize: contentSize,
        accessibilityNodeEntries: accessibilityNodeEntries,
        accessibilityEdgeEntries: accessibilityEdgeEntries,
        nodeAccessibilityValuesByID: nodeAccessibilityValuesByID,
        connectTargetsByNodeID: connectTargetsByNodeID
      ),
      routes: routes,
      labelPositions: labelPositions,
      portVisibility: portVisibility,
      portMarkerLayout: portMarkerLayout,
      visibleBounds: visibleBounds,
      contentSize: contentSize,
      accessibilityEdgeLabelsByID: accessibilityEdgeLabelsByID,
      accessibilityNodeEntries: accessibilityNodeEntries,
      accessibilityEdgeEntries: accessibilityEdgeEntries,
      nodeAccessibilityValuesByID: nodeAccessibilityValuesByID,
      connectTargetsByNodeID: connectTargetsByNodeID
    )
  }
}

struct PolicyCanvasAccessibilityNodeEntry: Equatable, Sendable, Identifiable {
  let id: String
  let label: String
}

struct PolicyCanvasAccessibilityEdgeEntry: Equatable, Sendable, Identifiable {
  let id: String
  let label: String
}
