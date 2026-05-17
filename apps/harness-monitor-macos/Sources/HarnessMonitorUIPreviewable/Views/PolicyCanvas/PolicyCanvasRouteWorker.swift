import OSLog
import SwiftUI

actor PolicyCanvasRouteWorker {
  private static let signposter = OSSignposter(
    subsystem: "io.harnessmonitor",
    category: "policy-canvas.perf"
  )

  private let router: any PolicyCanvasEdgeRouter
  private var cachedInput: PolicyCanvasRouteWorkerInput?
  private var cachedOutput: PolicyCanvasRouteWorkerOutput = .empty

  init(router: any PolicyCanvasEdgeRouter = PolicyCanvasMemoizedRouter(
    inner: PolicyCanvasVisibilityRouter()
  )) {
    self.router = router
  }

  func compute(input: PolicyCanvasRouteWorkerInput) -> PolicyCanvasRouteWorkerOutput {
    guard input != cachedInput else {
      return cachedOutput
    }
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

    let routes = input.displayedRoutes(router: router)
    let labelPositions = input.resolvedLabelPositions(routes: routes)
    let visibleBounds = input.visibleBounds(
      routes: routes,
      labelPositions: labelPositions
    )
    let nodeIndex = input.nodeIndex
    let portVisibility = input.portVisibility(routes: routes, nodeIndex: nodeIndex)
    let portMarkerLayout = input.portMarkerLayout(routes: routes, nodeIndex: nodeIndex)
    let accessibilityEdgeEntries = input.accessibilityEdgeEntries(nodeIndex: nodeIndex)
    let nodeAccessibilityValuesByID = input.nodeAccessibilityValuesByID(nodeIndex: nodeIndex)
    cachedInput = input
    cachedOutput = PolicyCanvasRouteWorkerOutput(
      routes: routes,
      labelPositions: labelPositions,
      portVisibility: portVisibility,
      portMarkerLayout: portMarkerLayout,
      visibleBounds: visibleBounds,
      contentSize: policyCanvasVisibleContentSize(visibleBounds: visibleBounds),
      accessibilityEdgeLabelsByID: Self.edgeLabelsByID(accessibilityEdgeEntries),
      accessibilityNodeEntries: input.accessibilityNodeEntries(),
      accessibilityEdgeEntries: accessibilityEdgeEntries,
      nodeAccessibilityValuesByID: nodeAccessibilityValuesByID,
      connectTargetsByNodeID: input.connectTargetsByNodeID()
    )
    return cachedOutput
  }

  func waitForIdle() async {}

  private static func edgeLabelsByID(
    _ entries: [PolicyCanvasAccessibilityEdgeEntry]
  ) -> [String: String] {
    Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.label) })
  }
}

struct PolicyCanvasRouteWorkerKey: Equatable {
  let graphGeneration: UInt64
  let nodeCount: Int
  let groupCount: Int
  let edgeCount: Int
  let fontScale: CGFloat
}

struct PolicyCanvasRouteWorkerInput: Equatable, Sendable {
  let nodes: [PolicyCanvasRouteNode]
  let groups: [PolicyCanvasGroup]
  let edges: [PolicyCanvasEdge]
  let fontScale: CGFloat

  init(
    nodes: [PolicyCanvasNode],
    groups: [PolicyCanvasGroup],
    edges: [PolicyCanvasEdge],
    fontScale: CGFloat
  ) {
    self.nodes = nodes.map(PolicyCanvasRouteNode.init(node:))
    self.groups = groups
    self.edges = edges
    self.fontScale = fontScale
  }

  var contentBounds: CGRect {
    let nodeBounds = nodes.reduce(CGRect.null) { partial, node in
      partial.union(node.frame)
    }
    let bounds = groups.reduce(nodeBounds) { partial, group in
      partial.union(group.frame)
    }
    guard !bounds.isNull else {
      return CGRect(origin: .zero, size: PolicyCanvasLayout.minimumCanvasSize)
    }
    return bounds
  }

  func visibleBounds(
    routes: [String: PolicyCanvasEdgeRoute],
    labelPositions: [String: CGPoint]
  ) -> CGRect {
    var bounds = contentBounds
    for route in routes.values {
      for point in route.points {
        let pointRect = CGRect(origin: point, size: .zero)
        bounds = bounds.isNull ? pointRect : bounds.union(pointRect)
      }
    }
    let labelMetrics = PolicyCanvasEdgeLabelMetrics(fontScale: fontScale)
    let labelSize = CGSize(
      width: PolicyCanvasLayout.edgeLabelMaxWidth,
      height: labelMetrics.height
    )
    for edge in edges {
      guard !edge.label.isEmpty, let position = labelPositions[edge.id] else {
        continue
      }
      let frame = CGRect(
        x: position.x - (labelSize.width / 2),
        y: position.y - (labelSize.height / 2),
        width: labelSize.width,
        height: labelSize.height
      )
      bounds = bounds.isNull ? frame : bounds.union(frame)
    }
    guard !bounds.isNull else {
      return CGRect(origin: .zero, size: PolicyCanvasLayout.minimumCanvasSize)
    }
    return bounds
  }

  func resolvedLabelPositions(
    routes: [String: PolicyCanvasEdgeRoute]
  ) -> [String: CGPoint] {
    let metrics = PolicyCanvasEdgeLabelMetrics(fontScale: fontScale)
    let labelledRoutes: [(id: String, route: PolicyCanvasEdgeRoute)] = edges.compactMap { edge in
      guard !edge.label.isEmpty, let route = routes[edge.id] else {
        return nil
      }
      return (id: edge.id, route: route)
    }
    return policyCanvasResolvedLabelPositions(
      routes: labelledRoutes,
      nodeFrames: nodes.map(\.frame) + policyCanvasGroupTitleFrames(groups),
      routeFrames: policyCanvasRouteFrames(labelledRoutes),
      labelSize: CGSize(width: PolicyCanvasLayout.edgeLabelMaxWidth, height: metrics.height)
    )
  }

  var nodeIndex: [String: PolicyCanvasRouteNode] {
    Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
  }
}

struct PolicyCanvasRouteWorkerOutput: Equatable, Sendable {
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
    let visibleBounds = input.contentBounds
    let nodeIndex = input.nodeIndex
    let accessibilityEdgeEntries = input.accessibilityEdgeEntries(nodeIndex: nodeIndex)
    let nodeAccessibilityValuesByID = input.nodeAccessibilityValuesByID(nodeIndex: nodeIndex)
    return Self(
      routes: [:],
      labelPositions: [:],
      portVisibility: [:],
      portMarkerLayout: .empty,
      visibleBounds: visibleBounds,
      contentSize: policyCanvasVisibleContentSize(visibleBounds: visibleBounds),
      accessibilityEdgeLabelsByID: Dictionary(
        uniqueKeysWithValues: accessibilityEdgeEntries.map { ($0.id, $0.label) }
      ),
      accessibilityNodeEntries: input.accessibilityNodeEntries(),
      accessibilityEdgeEntries: accessibilityEdgeEntries,
      nodeAccessibilityValuesByID: nodeAccessibilityValuesByID,
      connectTargetsByNodeID: input.connectTargetsByNodeID()
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

struct PolicyCanvasRouteNode: Equatable, Sendable {
  let id: String
  let title: String
  let accessibilityLabel: String
  let position: CGPoint
  let groupID: String?
  let inputPorts: [PolicyCanvasPort]
  let outputPorts: [PolicyCanvasPort]

  init(node: PolicyCanvasNode) {
    id = node.id
    title = node.title
    accessibilityLabel = "\(node.kind.title) \(node.title)"
    position = node.position
    groupID = node.groupID
    inputPorts = node.inputPorts
    outputPorts = node.outputPorts
  }

  var frame: CGRect {
    CGRect(origin: position, size: PolicyCanvasLayout.nodeSize)
  }
}
