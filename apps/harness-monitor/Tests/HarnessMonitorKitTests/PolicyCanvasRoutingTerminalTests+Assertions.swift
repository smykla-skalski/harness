import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension PolicyCanvasRoutingTerminalTests {
  func assertTerminalAnchorSpacing(
    scenario: PolicyCanvasTerminalScenario,
    assertion: PolicyCanvasTerminalAssertion
  ) {
    let familyPreferences = policyCanvasRouteFamilyPreferences(edges: scenario.edges)
    let groups = Dictionary(grouping: scenario.edges) { edge in
      PolicyCanvasRouteEndpointTestKey(edge[keyPath: assertion.endpoint])
    }
    for groupEdges in groups.values where groupEdges.count > 1 {
      let entries = groupEdges.compactMap { edge in
        terminalEntry(edge: edge, scenario: scenario, assertion: assertion).map { (edge, $0) }
      }
      let representativeEntries = representativeEntries(
        entries: entries,
        assertion: assertion,
        familyPreferences: familyPreferences
      )
      for leftIndex in representativeEntries.indices {
        for rightIndex in representativeEntries.index(
          after: leftIndex)..<representativeEntries.endIndex
        {
          let left = representativeEntries[leftIndex]
          let right = representativeEntries[rightIndex]
          guard left.side == right.side else {
            continue
          }
          let distance = hypot(left.point.x - right.point.x, left.point.y - right.point.y)
          #expect(
            distance >= min(left.spacing, right.spacing) - 0.5,
            "\(assertion.label) anchors \(left.id) and \(right.id) are closer than port spacing"
          )
        }
      }
    }
  }

  func terminalEntry(
    edge: PolicyCanvasEdge,
    scenario: PolicyCanvasTerminalScenario,
    assertion: PolicyCanvasTerminalAssertion
  ) -> PolicyCanvasTerminalEntry? {
    guard
      let route = scenario.routes[edge.id],
      let point = assertion.routePoint(route)
    else {
      return nil
    }
    let side = assertion.routeSide(route)
    let spacing = scenario.viewModel.portSpacing(
      for: edge[keyPath: assertion.endpoint],
      side: side
    )
    return PolicyCanvasTerminalEntry(id: edge.id, point: point, spacing: spacing, side: side)
  }

  func assertSeparateTerminalAnchors(
    scenario: PolicyCanvasTerminalScenario,
    endpoint: KeyPath<PolicyCanvasEdge, PolicyCanvasPortEndpoint>,
    routePoint: @escaping (PolicyCanvasEdgeRoute) -> CGPoint?,
    label: String
  ) {
    let assertion = PolicyCanvasTerminalAssertion(
      role: endpoint == \.source ? .source : .target,
      endpoint: endpoint,
      routePoint: routePoint,
      routeSide: { _ in nil },
      label: label
    )
    let familyPreferences = policyCanvasRouteFamilyPreferences(edges: scenario.edges)
    let groups = Dictionary(grouping: scenario.edges) { edge in
      PolicyCanvasRouteEndpointTestKey(edge[keyPath: endpoint])
    }
    for groupEdges in groups.values where groupEdges.count > 1 {
      let entries = groupEdges.compactMap { edge -> (PolicyCanvasEdge, PolicyCanvasPointKey)? in
        guard let route = scenario.routes[edge.id], let point = routePoint(route) else {
          return nil
        }
        return (edge, PolicyCanvasPointKey(point))
      }
      let representativePoints = representativePoints(
        entries: entries,
        assertion: assertion,
        familyPreferences: familyPreferences
      )
      #expect(
        Set(representativePoints).count == representativePoints.count,
        "\(label) endpoint routes should not share the same physical anchor"
      )
    }
  }

  func representativeEntries(
    entries: [(PolicyCanvasEdge, PolicyCanvasTerminalEntry)],
    assertion: PolicyCanvasTerminalAssertion,
    familyPreferences: [String: PolicyCanvasRouteFamilyPreference]
  ) -> [PolicyCanvasTerminalEntry] {
    Dictionary(grouping: entries) { edge, _ in
      physicalAnchorGroupID(
        edge: edge,
        assertion: assertion,
        familyPreferences: familyPreferences
      )
    }
    .compactMap { groupID, groupedEntries -> PolicyCanvasTerminalEntry? in
      let points = Set(groupedEntries.map { PolicyCanvasPointKey($0.1.point) })
      #expect(
        points.count == 1,
        "\(assertion.label) collapsed group \(groupID) should share one physical anchor"
      )
      return groupedEntries.first?.1
    }
  }

  func representativePoints(
    entries: [(PolicyCanvasEdge, PolicyCanvasPointKey)],
    assertion: PolicyCanvasTerminalAssertion,
    familyPreferences: [String: PolicyCanvasRouteFamilyPreference]
  ) -> [PolicyCanvasPointKey] {
    Dictionary(grouping: entries) { edge, _ in
      physicalAnchorGroupID(
        edge: edge,
        assertion: assertion,
        familyPreferences: familyPreferences
      )
    }
    .compactMap { groupID, groupedEntries -> PolicyCanvasPointKey? in
      let points = Set(groupedEntries.map(\.1))
      #expect(
        points.count == 1,
        "\(assertion.label) collapsed group \(groupID) should share one physical anchor"
      )
      return points.first
    }
  }

  func physicalAnchorGroupID(
    edge: PolicyCanvasEdge,
    assertion: PolicyCanvasTerminalAssertion,
    familyPreferences: [String: PolicyCanvasRouteFamilyPreference]
  ) -> String {
    if assertion.role == .source,
      let collapsedGroup = policyCanvasCollapsedSourceTerminalGroup(
        edge: edge,
        familyPreference: familyPreferences[edge.id, default: .none]
      )
    {
      return "source-collapse|\(collapsedGroup)"
    }
    return edge.id
  }

  func assertMarkerOffsets(
    scenario: PolicyCanvasTerminalScenario,
    markerLayout: PolicyCanvasPortMarkerLayout,
    assertion: PolicyCanvasTerminalAssertion
  ) {
    for edge in scenario.edges {
      guard
        let route = scenario.routes[edge.id],
        let point = assertion.routePoint(route),
        let side = assertion.routeSide(route),
        let base = scenario.viewModel.portAnchorCandidates(for: edge[keyPath: assertion.endpoint])
          .first(where: { $0.side == side })?.point
      else {
        continue
      }
      let offset = axisOffset(from: base, to: point, side: side)
      let endpoint = edge[keyPath: assertion.endpoint]
      let markers = markerLayout.markers(for: endpoint, side: side, isVisible: true)
      if markers.contains(where: { abs($0.axisOffset - offset) < 0.5 }) {
        continue
      }
      // Fan-collapse case: when a single-edge port's route escapes onto a
      // sibling port's lane (e.g. action:router's "unsafe" line leaves on the
      // same dot as "mutate"), the terminal still lands on a drawn dot - just
      // one owned by a neighbouring port. Accept the route as long as its
      // terminal sits within a dot radius of some visible marker on the same
      // node + side, so no line end floats free of the dot grid.
      let axis = (side == .leading || side == .trailing) ? point.y : point.x
      let dotPositions = markerAxisPositionsOnNodeSide(
        scenario: scenario,
        markerLayout: markerLayout,
        endpoint: endpoint,
        side: side
      )
      #expect(
        dotPositions.contains { abs($0 - axis) <= PolicyCanvasLayout.portDiameter / 2 },
        """
        \(assertion.label) terminal \(edge.id) at \(axis) lands on no visible \
        dot on side \(side); dots \(dotPositions)
        """
      )
    }
  }

  func markerAxisPositionsOnNodeSide(
    scenario: PolicyCanvasTerminalScenario,
    markerLayout: PolicyCanvasPortMarkerLayout,
    endpoint: PolicyCanvasPortEndpoint,
    side: PolicyCanvasPortSide
  ) -> [CGFloat] {
    guard let node = scenario.viewModel.node(endpoint.nodeID) else {
      return []
    }
    let ports = endpoint.kind == .output ? node.outputPorts : node.inputPorts
    return ports.flatMap { port -> [CGFloat] in
      let portEndpoint = PolicyCanvasPortEndpoint(
        nodeID: endpoint.nodeID,
        portID: port.id,
        kind: endpoint.kind
      )
      guard
        let base = scenario.viewModel.portAnchorCandidates(for: portEndpoint)
          .first(where: { $0.side == side })?.point
      else {
        return []
      }
      let baseAxis = (side == .leading || side == .trailing) ? base.y : base.x
      return markerLayout.markers(for: portEndpoint, side: side, isVisible: true)
        .map { baseAxis + $0.axisOffset }
    }
  }

  func axisOffset(
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
}
