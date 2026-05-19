import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas route terminals")
@MainActor
struct PolicyCanvasRoutingTerminalTests {
  @Test("same endpoint routes use separate terminal anchors")
  func sameEndpointRoutesUseSeparateTerminalAnchors() {
    let (_, edges, routes) = defaultDisplayedRoutes()

    assertSeparateTerminalAnchors(
      edges: edges,
      routes: routes,
      endpoint: \.source,
      routePoint: { $0.points.first },
      label: "source"
    )
    assertSeparateTerminalAnchors(
      edges: edges,
      routes: routes,
      endpoint: \.target,
      routePoint: { $0.points.last },
      label: "target"
    )
  }

  @Test("same endpoint route anchors keep port spacing")
  func sameEndpointRouteAnchorsKeepPortSpacing() {
    let (viewModel, edges, routes) = defaultDisplayedRoutes()

    assertTerminalAnchorSpacing(
      viewModel: viewModel,
      edges: edges,
      routes: routes,
      endpoint: \.source,
      routePoint: { $0.points.first },
      routeSide: policyCanvasRouteSourceSide,
      label: "source"
    )
    assertTerminalAnchorSpacing(
      viewModel: viewModel,
      edges: edges,
      routes: routes,
      endpoint: \.target,
      routePoint: { $0.points.last },
      routeSide: policyCanvasRouteTargetSide,
      label: "target"
    )
  }

  @Test("port marker layout matches route terminal offsets")
  func portMarkerLayoutMatchesRouteTerminalOffsets() {
    let (viewModel, edges, routes) = defaultDisplayedRoutes()
    let input = PolicyCanvasRouteWorkerInput(
      nodes: viewModel.nodes,
      groups: viewModel.groups,
      edges: edges,
      fontScale: 1
    )
    let prepared = PolicyCanvasPreparedRouteInput(input: input)
    let markerLayout = prepared.portMarkerLayout(routes: routes, nodeIndex: prepared.nodeIndex)

    assertMarkerOffsets(
      viewModel: viewModel,
      edges: edges,
      routes: routes,
      markerLayout: markerLayout,
      endpoint: \.source,
      routePoint: { $0.points.first },
      routeSide: policyCanvasRouteSourceSide,
      label: "source"
    )
    assertMarkerOffsets(
      viewModel: viewModel,
      edges: edges,
      routes: routes,
      markerLayout: markerLayout,
      endpoint: \.target,
      routePoint: { $0.points.last },
      routeSide: policyCanvasRouteTargetSide,
      label: "target"
    )
  }

  @Test("default graph displayed routes keep port spacing between route edges")
  func defaultGraphDisplayedRoutesKeepPortSpacingBetweenRouteEdges() {
    let (viewModel, edges, routes) = defaultDisplayedRoutes()

    for leftIndex in edges.indices {
      for rightIndex in edges.index(after: leftIndex)..<edges.endIndex {
        let left = edges[leftIndex]
        let right = edges[rightIndex]
        guard let leftRoute = routes[left.id], let rightRoute = routes[right.id] else {
          continue
        }
        let minimumSpacing = min(
          policyCanvasRouteMinimumSpacing(
            viewModel: viewModel,
            edge: left,
            route: leftRoute
          ),
          policyCanvasRouteMinimumSpacing(
            viewModel: viewModel,
            edge: right,
            route: rightRoute
          )
        )
        #expect(
          !policyCanvasRouteViolatesMinimumSpacing(
            leftRoute,
            with: [rightRoute],
            minimumSpacing: minimumSpacing
          ),
          "\(left.id) and \(right.id) route edges are closer than port spacing"
        )
      }
    }
  }

  @Test("default graph displayed routes do not share rendered collinear segments")
  func defaultGraphDisplayedRoutesDoNotShareRenderedCollinearSegments() {
    let (_, edges, routes) = defaultDisplayedRoutes()

    for leftIndex in edges.indices {
      for rightIndex in edges.index(after: leftIndex)..<edges.endIndex {
        let left = edges[leftIndex]
        let right = edges[rightIndex]
        guard let leftRoute = routes[left.id], let rightRoute = routes[right.id] else {
          continue
        }
        if routesShareRenderedCollinearRange(leftRoute, rightRoute) {
          #expect(left.id == right.id)
        }
      }
    }
  }

  // swiftlint:disable:next large_tuple
  private func defaultDisplayedRoutes() -> (
    viewModel: PolicyCanvasViewModel,
    edges: [PolicyCanvasEdge],
    routes: [String: PolicyCanvasEdgeRoute]
  ) {
    let document = PreviewFixtures.policyCanvasPipelineDocument()
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: document, simulation: nil, audit: nil)
    let edges = viewModel.edges
    return (
      viewModel: viewModel,
      edges: edges,
      routes: policyCanvasDisplayedRoutes(
        viewModel: viewModel,
        edges: edges,
        portAnchors: viewModel.portAnchors(for: edges),
        router: PolicyCanvasVisibilityRouter()
      )
    )
  }

  // swiftlint:disable:next function_parameter_count
  private func assertTerminalAnchorSpacing(
    viewModel: PolicyCanvasViewModel,
    edges: [PolicyCanvasEdge],
    routes: [String: PolicyCanvasEdgeRoute],
    endpoint: KeyPath<PolicyCanvasEdge, PolicyCanvasPortEndpoint>,
    routePoint: (PolicyCanvasEdgeRoute) -> CGPoint?,
    routeSide: (PolicyCanvasEdgeRoute) -> PolicyCanvasPortSide?,
    label: String
  ) {
    let groups = Dictionary(grouping: edges) { edge in
      PolicyCanvasRouteEndpointTestKey(edge[keyPath: endpoint])
    }
    for groupEdges in groups.values where groupEdges.count > 1 {
      let entries = groupEdges.compactMap {
        // swiftlint:disable:next closure_parameter_position large_tuple
        edge -> (String, CGPoint, CGFloat, PolicyCanvasPortSide?)? in
        guard let route = routes[edge.id], let point = routePoint(route) else {
          return nil
        }
        let side = routeSide(route)
        let spacing = viewModel.portSpacing(
          for: edge[keyPath: endpoint],
          side: side
        )
        return (edge.id, point, spacing, side)
      }
      for leftIndex in entries.indices {
        for rightIndex in entries.index(after: leftIndex)..<entries.endIndex {
          let left = entries[leftIndex]
          let right = entries[rightIndex]
          guard left.3 == right.3 else {
            continue
          }
          let distance = hypot(left.1.x - right.1.x, left.1.y - right.1.y)
          #expect(
            distance >= min(left.2, right.2) - 0.5,
            "\(label) anchors \(left.0) and \(right.0) are closer than port spacing"
          )
        }
      }
    }
  }

  private func assertSeparateTerminalAnchors(
    edges: [PolicyCanvasEdge],
    routes: [String: PolicyCanvasEdgeRoute],
    endpoint: KeyPath<PolicyCanvasEdge, PolicyCanvasPortEndpoint>,
    routePoint: (PolicyCanvasEdgeRoute) -> CGPoint?,
    label: String
  ) {
    let groups = Dictionary(grouping: edges) { edge in
      PolicyCanvasRouteEndpointTestKey(edge[keyPath: endpoint])
    }
    for groupEdges in groups.values where groupEdges.count > 1 {
      let points = groupEdges.compactMap { edge -> PolicyCanvasPointKey? in
        guard let route = routes[edge.id], let point = routePoint(route) else {
          return nil
        }
        return PolicyCanvasPointKey(point)
      }
      #expect(
        Set(points).count == groupEdges.count,
        "\(label) endpoint routes should not share the same physical anchor"
      )
    }
  }

  // swiftlint:disable:next function_parameter_count
  private func assertMarkerOffsets(
    viewModel: PolicyCanvasViewModel,
    edges: [PolicyCanvasEdge],
    routes: [String: PolicyCanvasEdgeRoute],
    markerLayout: PolicyCanvasPortMarkerLayout,
    endpoint: KeyPath<PolicyCanvasEdge, PolicyCanvasPortEndpoint>,
    routePoint: (PolicyCanvasEdgeRoute) -> CGPoint?,
    routeSide: (PolicyCanvasEdgeRoute) -> PolicyCanvasPortSide?,
    label: String
  ) {
    for edge in edges {
      guard
        let route = routes[edge.id],
        let point = routePoint(route),
        let side = routeSide(route),
        let base = viewModel.portAnchorCandidates(for: edge[keyPath: endpoint])
          .first(where: { $0.side == side })?.point
      else {
        continue
      }
      let offset = axisOffset(from: base, to: point, side: side)
      let markers = markerLayout.markers(
        for: edge[keyPath: endpoint],
        side: side,
        isVisible: true
      )
      #expect(
        markers.contains { abs($0.axisOffset - offset) < 0.5 },
        "\(label) marker missing \(edge.id) terminal offset \(offset)"
      )
    }
  }

  private func axisOffset(
    from base: CGPoint,
    to point: CGPoint,
    side: PolicyCanvasPortSide
  ) -> CGFloat {
    switch side {
    case .leading, .trailing:
      point.y - base.y
    case .top, .bottom:
      point.x - base.x
    }
  }

  private func routesShareRenderedCollinearRange(
    _ left: PolicyCanvasEdgeRoute,
    _ right: PolicyCanvasEdgeRoute
  ) -> Bool {
    routeSegments(left).contains { leftSegment in
      routeSegments(right).contains { rightSegment in
        leftSegment.sharesCollinearRange(with: rightSegment)
      }
    }
  }

  private func routeSegments(_ route: PolicyCanvasEdgeRoute) -> [PolicyCanvasTerminalTestSegment] {
    zip(route.points, route.points.dropFirst()).compactMap { start, end in
      guard start != end else {
        return nil
      }
      return PolicyCanvasTerminalTestSegment(start: start, end: end)
    }
  }
}

private struct PolicyCanvasRouteEndpointTestKey: Hashable {
  let nodeID: String
  let portID: String
  let kind: PolicyCanvasPortKind

  init(_ endpoint: PolicyCanvasPortEndpoint) {
    nodeID = endpoint.nodeID
    portID = endpoint.portID
    kind = endpoint.kind
  }
}

private struct PolicyCanvasPointKey: Hashable {
  let x: Int
  let y: Int

  init(_ point: CGPoint) {
    x = Int((point.x * 1_000).rounded())
    y = Int((point.y * 1_000).rounded())
  }
}

private struct PolicyCanvasTerminalTestSegment {
  let start: CGPoint
  let end: CGPoint

  var isHorizontal: Bool {
    abs(start.y - end.y) < 0.001
  }

  var isVertical: Bool {
    abs(start.x - end.x) < 0.001
  }

  func sharesCollinearRange(with other: Self) -> Bool {
    if isHorizontal, other.isHorizontal, abs(start.y - other.start.y) < 0.001 {
      return overlap(
        min(start.x, end.x)...max(start.x, end.x),
        min(other.start.x, other.end.x)...max(other.start.x, other.end.x)
      ) > 0.001
    }
    if isVertical, other.isVertical, abs(start.x - other.start.x) < 0.001 {
      return overlap(
        min(start.y, end.y)...max(start.y, end.y),
        min(other.start.y, other.end.y)...max(other.start.y, other.end.y)
      ) > 0.001
    }
    return false
  }

  private func overlap(_ left: ClosedRange<CGFloat>, _ right: ClosedRange<CGFloat>) -> CGFloat {
    max(0, min(left.upperBound, right.upperBound) - max(left.lowerBound, right.lowerBound))
  }
}
