import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas route terminals")
@MainActor
struct PolicyCanvasRoutingTerminalTests {
  @Test("same endpoint routes use separate terminal anchors")
  func sameEndpointRoutesUseSeparateTerminalAnchors() {
    let scenario = defaultDisplayedRoutes()

    assertSeparateTerminalAnchors(
      scenario: scenario,
      endpoint: \.source,
      routePoint: { $0.points.first },
      label: "source"
    )
    assertSeparateTerminalAnchors(
      scenario: scenario,
      endpoint: \.target,
      routePoint: { $0.points.last },
      label: "target"
    )
  }

  @Test("same endpoint route anchors keep port spacing")
  func sameEndpointRouteAnchorsKeepPortSpacing() {
    let scenario = defaultDisplayedRoutes()

    assertTerminalAnchorSpacing(
      scenario: scenario,
      assertion: PolicyCanvasTerminalAssertion(
        role: .source,
        endpoint: \.source,
        routePoint: { $0.points.first },
        routeSide: policyCanvasRouteSourceSide,
        label: "source"
      )
    )
    assertTerminalAnchorSpacing(
      scenario: scenario,
      assertion: PolicyCanvasTerminalAssertion(
        role: .target,
        endpoint: \.target,
        routePoint: { $0.points.last },
        routeSide: policyCanvasRouteTargetSide,
        label: "target"
      )
    )
  }

  @Test("port marker layout matches route terminal offsets")
  func portMarkerLayoutMatchesRouteTerminalOffsets() {
    let scenario = defaultDisplayedRoutes()
    let input = PolicyCanvasRouteWorkerInput(
      nodes: scenario.viewModel.nodes,
      groups: scenario.viewModel.groups,
      edges: scenario.edges,
      fontScale: 1
    )
    let prepared = PolicyCanvasPreparedRouteInput(input: input)
    let markerLayout = prepared.portMarkerLayout(
      routes: scenario.routes,
      nodeIndex: prepared.nodeIndex
    )

    assertMarkerOffsets(
      scenario: scenario,
      markerLayout: markerLayout,
      assertion: PolicyCanvasTerminalAssertion(
        role: .source,
        endpoint: \.source,
        routePoint: { $0.points.first },
        routeSide: policyCanvasRouteSourceSide,
        label: "source"
      )
    )
    assertMarkerOffsets(
      scenario: scenario,
      markerLayout: markerLayout,
      assertion: PolicyCanvasTerminalAssertion(
        role: .target,
        endpoint: \.target,
        routePoint: { $0.points.last },
        routeSide: policyCanvasRouteTargetSide,
        label: "target"
      )
    )
  }

  @Test("merge-deny failure family shares one bottom source port marker")
  func mergeDenyFailureRoutesShareOneBottomSourcePortMarker() {
    let scenario = defaultDisplayedRoutes()
    let input = PolicyCanvasRouteWorkerInput(
      nodes: scenario.viewModel.nodes,
      groups: scenario.viewModel.groups,
      edges: scenario.edges,
      fontScale: 1
    )
    let prepared = PolicyCanvasPreparedRouteInput(input: input)
    let markerLayout = prepared.portMarkerLayout(
      routes: scenario.routes,
      nodeIndex: prepared.nodeIndex
    )
    let familyIDs = [
      "edge:evidence-fail:checks-not-green",
      "edge:evidence-fail:branch-protection-blocked",
      "edge:evidence-fail:reviewer-not-approved",
      "edge:evidence-fail:unresolved-requested-changes",
    ]
    let familyEdges = familyIDs.compactMap { edgeID in
      scenario.edges.first(where: { $0.id == edgeID })
    }
    let sourceAssertion = PolicyCanvasTerminalAssertion(
      role: .source,
      endpoint: \.source,
      routePoint: { $0.points.first },
      routeSide: policyCanvasRouteSourceSide,
      label: "source"
    )
    let entries = familyEdges.compactMap { edge in
      terminalEntry(edge: edge, scenario: scenario, assertion: sourceAssertion)
    }

    #expect(entries.count == familyIDs.count)
    #expect(entries.allSatisfy { $0.side == .bottom })
    #expect(Set(entries.map { PolicyCanvasPointKey($0.point) }).count == 1)

    let failEndpoint = PolicyCanvasPortEndpoint(
      nodeID: "evidence:merge",
      portID: "fail",
      kind: .output
    )
    #expect(markerLayout.markers(for: failEndpoint, side: .bottom, isVisible: true).count == 1)
  }

  @Test("merge-deny failure routes keep a compact top terminal band")
  func mergeDenyFailureRoutesKeepACompactTopTerminalBand() {
    let scenario = defaultDisplayedRoutes()
    let familyIDs = [
      "edge:evidence-fail:checks-not-green",
      "edge:evidence-fail:branch-protection-blocked",
      "edge:evidence-fail:reviewer-not-approved",
      "edge:evidence-fail:unresolved-requested-changes",
    ]
    let familyEdges = familyIDs.compactMap { edgeID in
      scenario.edges.first(where: { $0.id == edgeID })
    }
    let targetAssertion = PolicyCanvasTerminalAssertion(
      role: .target,
      endpoint: \.target,
      routePoint: { $0.points.last },
      routeSide: policyCanvasRouteTargetSide,
      label: "target"
    )
    let entries = familyEdges.compactMap { edge in
      terminalEntry(edge: edge, scenario: scenario, assertion: targetAssertion)
    }

    #expect(entries.count == familyIDs.count)
    #expect(entries.allSatisfy { $0.side == .top })

    guard
      let firstEntry = entries.first
    else {
      Issue.record("Expected merge-deny failure family terminal entries")
      return
    }

    let sharedBandY = firstEntry.point.y
    let terminalSpan = (entries.map(\.point.x).max() ?? 0) - (entries.map(\.point.x).min() ?? 0)

    for entry in entries {
      #expect(
        abs(entry.point.y - sharedBandY) < 0.5,
        "\(entry.id) drifted off the shared top terminal band"
      )
    }
    #expect(
      terminalSpan <= PolicyCanvasLayout.nodeSize.width / 2,
      "merge-deny top terminal band widened to \(terminalSpan), exceeding the compact fan-in width budget"
    )
  }

  @Test("merge evidence routes checks-pass horizontally across the merge group")
  func mergeEvidenceRoutesChecksPassHorizontally() {
    let scenario = defaultDisplayedRoutes()
    let input = PolicyCanvasRouteWorkerInput(
      nodes: scenario.viewModel.nodes,
      groups: scenario.viewModel.groups,
      edges: scenario.edges,
      fontScale: 1
    )
    let prepared = PolicyCanvasPreparedRouteInput(input: input)
    let markerLayout = prepared.portMarkerLayout(
      routes: scenario.routes,
      nodeIndex: prepared.nodeIndex
    )
    guard let node = scenario.viewModel.node("evidence:merge") else {
      Issue.record("Expected Merge evidence node in default policy fixture")
      return
    }
    guard
      let edge = scenario.edges.first(where: { $0.id == "edge:evidence-pass" }),
      let route = scenario.routes[edge.id],
      let sourceIndex = node.outputPorts.firstIndex(where: { $0.id == edge.source.portID }),
      let targetNode = scenario.viewModel.node("risk:merge")
    else {
      Issue.record("Expected checks-pass route inside the merge group")
      return
    }
    let sourceEndpoint = PolicyCanvasPortEndpoint(
      nodeID: node.id,
      portID: edge.source.portID,
      kind: .output
    )
    let targetEndpoint = PolicyCanvasPortEndpoint(
      nodeID: targetNode.id,
      portID: edge.target.portID,
      kind: .input
    )
    #expect(policyCanvasRouteSourceSide(route) == .trailing)
    #expect(policyCanvasRouteTargetSide(route) == .leading)

    let sourceMarkers = markerLayout.markers(for: sourceEndpoint, side: .trailing, isVisible: true)
    let targetMarkers = markerLayout.markers(for: targetEndpoint, side: .leading, isVisible: true)
    #expect(sourceMarkers.count == 1)
    #expect(targetMarkers.count == 1)
    let renderedSourceY = PolicyCanvasLayout.portY(index: sourceIndex, count: node.outputPorts.count)
      + sourceMarkers[0].axisOffset
    #expect(renderedSourceY >= 0)
    #expect(renderedSourceY <= PolicyCanvasLayout.nodeSize.height)
  }

  private func defaultDisplayedRoutes() -> PolicyCanvasTerminalScenario {
    let document = PreviewFixtures.policyCanvasPipelineDocument()
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: document, simulation: nil, audit: nil)
    let edges = viewModel.edges
    return PolicyCanvasTerminalScenario(
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

  private func assertTerminalAnchorSpacing(
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
        for rightIndex in representativeEntries.index(after: leftIndex)..<representativeEntries.endIndex {
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

  private func terminalEntry(
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

  private func assertSeparateTerminalAnchors(
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

  private func representativeEntries(
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

  private func representativePoints(
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

  private func physicalAnchorGroupID(
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

  private func assertMarkerOffsets(
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
      let markers = markerLayout.markers(
        for: edge[keyPath: assertion.endpoint],
        side: side,
        isVisible: true
      )
      #expect(
        markers.contains { abs($0.axisOffset - offset) < 0.5 },
        "\(assertion.label) marker missing \(edge.id) terminal offset \(offset)"
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

}

private struct PolicyCanvasTerminalScenario {
  let viewModel: PolicyCanvasViewModel
  let edges: [PolicyCanvasEdge]
  let routes: [String: PolicyCanvasEdgeRoute]
}

private struct PolicyCanvasTerminalAssertion {
  let role: PolicyCanvasRouteEndpointRole
  let endpoint: KeyPath<PolicyCanvasEdge, PolicyCanvasPortEndpoint>
  let routePoint: (PolicyCanvasEdgeRoute) -> CGPoint?
  let routeSide: (PolicyCanvasEdgeRoute) -> PolicyCanvasPortSide?
  let label: String
}

private struct PolicyCanvasTerminalEntry {
  let id: String
  let point: CGPoint
  let spacing: CGFloat
  let side: PolicyCanvasPortSide?
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
