import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

extension PolicyCanvasRoutingScreenshotRegressionTests {
  @Test("default graph action-family duplicate labels stay off the shared departure trunk")
  func defaultGraphActionFamilyDuplicateLabelsStayOffTheSharedDepartureTrunk() {
    let (viewModel, routes) = defaultDisplayedRoutes()
    let metrics = PolicyCanvasEdgeLabelMetrics(fontScale: 1)
    let placementRoutes = Self.actionTerminalEdgeIDs.compactMap { edgeID in
      routes[edgeID].map {
        PolicyCanvasLabelPlacementRoute(
          id: edgeID,
          label: "action in",
          route: $0,
          size: metrics.size(for: "action in")
        )
      }
    }
    #expect(placementRoutes.count == Self.actionTerminalEdgeIDs.count)
    guard let trunkY = dominantSharedHorizontalTrunkY(routes: placementRoutes.map(\.route)) else {
      // Per-target corridor design: action-terminal edges route to
      // distinct targets and need not share a horizontal trunk. Nothing
      // to assert.
      return
    }

    let positions = policyCanvasResolvedLabelPositions(
      routes: placementRoutes,
      nodeFrames: defaultNodeAndGroupFrames(viewModel: viewModel),
      routeFrames: policyCanvasRouteFrames(placementRoutes)
    )
    let labelsOnTrunk = Self.actionTerminalEdgeIDs.compactMap { positions[$0] }.filter {
      abs($0.y - trunkY) <= PolicyCanvasLayout.gridSize
    }

    #expect(
      labelsOnTrunk.count <= 1,
      """
      Expected at most one action-family duplicate label on the shared trunk \
      at y=\(trunkY); saw \(labelsOnTrunk)
      """
    )
  }

  @Test("default graph risk labels stay off the shared departure trunk")
  func defaultGraphRiskLabelsStayOffTheSharedDepartureTrunk() {
    let (viewModel, routes) = defaultDisplayedRoutes()
    let metrics = PolicyCanvasEdgeLabelMetrics(fontScale: 1)
    let placementRoutes = labelPlacementRoutes(
      for: Self.riskFamilyEdgeIDs,
      viewModel: viewModel,
      routes: routes,
      metrics: metrics
    )
    #expect(placementRoutes.count == Self.riskFamilyEdgeIDs.count)
    guard let trunkY = dominantSharedHorizontalTrunkY(routes: placementRoutes.map(\.route)) else {
      // Per-target corridor design: risk-family edges route to distinct
      // targets and need not share a horizontal trunk. Nothing to assert.
      return
    }

    let positions = policyCanvasResolvedLabelPositions(
      routes: placementRoutes,
      nodeFrames: defaultNodeAndGroupFrames(viewModel: viewModel),
      routeFrames: policyCanvasRouteFrames(placementRoutes)
    )
    let labelsOnTrunk = Self.riskFamilyEdgeIDs.compactMap { positions[$0] }.filter {
      abs($0.y - trunkY) <= PolicyCanvasLayout.gridSize
    }

    #expect(
      labelsOnTrunk.count <= 1,
      """
      Expected at most one risk-family label on the shared trunk \
      at y=\(trunkY); saw \(labelsOnTrunk)
      """
    )
  }

  @Test("default graph merge-to-terminal labels stay off the shared vertical corridor")
  func defaultGraphMergeToTerminalLabelsStayOffTheSharedVerticalCorridor() {
    let (viewModel, routes) = defaultDisplayedRoutes()
    let metrics = PolicyCanvasEdgeLabelMetrics(fontScale: 1)
    let placementRoutes = labelPlacementRoutes(
      for: Self.mergeToTerminalLabelEdgeIDs,
      viewModel: viewModel,
      routes: routes,
      metrics: metrics
    )
    #expect(placementRoutes.count == Self.mergeToTerminalLabelEdgeIDs.count)
    guard let trunk = rightmostSharedVerticalTrunk(routes: placementRoutes.map(\.route)) else {
      // Per-target corridor design: merge-to-terminal edges route to
      // distinct targets and need not share a vertical trunk. Nothing to
      // assert.
      return
    }

    let positions = policyCanvasResolvedLabelPositions(
      routes: placementRoutes,
      nodeFrames: defaultNodeAndGroupFrames(viewModel: viewModel),
      routeFrames: policyCanvasRouteFrames(placementRoutes)
    )
    let labelsOnTrunk = placementRoutes.compactMap { route in
      positions[route.id].map {
        labelFrame(center: $0, size: route.size)
      }
    }.filter { $0.intersects(verticalTrunkFrame(trunk)) }

    #expect(
      labelsOnTrunk.count <= 1,
      """
      Expected at most one merge-to-terminal label on shared vertical corridor \
      x=\(trunk.x), saw \(labelsOnTrunk.count) with frames \(labelsOnTrunk)
      """
    )
  }

  @Test("default graph middle merge-to-terminal labels stay off the shared horizontal corridor")
  func defaultGraphMiddleMergeToTerminalLabelsStayOffTheSharedHorizontalCorridor() {
    let (viewModel, routes) = defaultDisplayedRoutes()
    let metrics = PolicyCanvasEdgeLabelMetrics(fontScale: 1)
    let placementRoutes = labelPlacementRoutes(
      for: Self.middleMergeToTerminalEdgeIDs,
      viewModel: viewModel,
      routes: routes,
      metrics: metrics
    )
    #expect(placementRoutes.count == Self.middleMergeToTerminalEdgeIDs.count)
    guard let trunkY = dominantSharedHorizontalTrunkY(routes: placementRoutes.map(\.route)) else {
      // Per-target corridor design (Brandes-Kopf Y assignment): middle
      // merge-to-terminal edges route to distinct horizontal bands and need
      // not share a single trunk. Nothing to assert.
      return
    }

    let positions = policyCanvasResolvedLabelPositions(
      routes: placementRoutes,
      nodeFrames: defaultNodeAndGroupFrames(viewModel: viewModel),
      routeFrames: policyCanvasRouteFrames(placementRoutes)
    )
    let labelsOnTrunk = placementRoutes.compactMap { route in
      positions[route.id].map {
        labelFrame(center: $0, size: route.size)
      }
    }.filter { frame in
      abs(frame.midY - trunkY) <= PolicyCanvasLayout.gridSize
    }

    #expect(
      labelsOnTrunk.isEmpty,
      """
      Expected middle merge-to-terminal labels to leave the shared horizontal \
      corridor at y=\(trunkY); saw \(labelsOnTrunk)
      """
    )
  }

  // The merge-deny fail family now folds into one merged wire with a single
  // "evidence failure" label, so the duplicate-label collision these two tests
  // guarded (a shared vertical corridor and a single-column pile-up) can no
  // longer occur. The merged wire's lone label placement is covered by
  // PolicyCanvasFailureFanInLabelTests; the fold itself by
  // PolicyCanvasMergedFanInTests.

  @Test("default graph risk labels stay off the shared vertical departure corridor")
  func defaultGraphRiskLabelsStayOffTheSharedVerticalDepartureCorridor() {
    let (viewModel, routes) = defaultDisplayedRoutes()
    let metrics = PolicyCanvasEdgeLabelMetrics(fontScale: 1)
    let placementRoutes = labelPlacementRoutes(
      for: Self.riskFamilyEdgeIDs,
      viewModel: viewModel,
      routes: routes,
      metrics: metrics
    )
    #expect(placementRoutes.count == Self.riskFamilyEdgeIDs.count)
    guard let trunk = rightmostSharedVerticalTrunk(routes: placementRoutes.map(\.route)) else {
      // Per-target corridor design: risk-family edges route to distinct
      // targets and need not share a vertical departure trunk. Nothing to
      // assert.
      return
    }

    let positions = policyCanvasResolvedLabelPositions(
      routes: placementRoutes,
      nodeFrames: defaultNodeAndGroupFrames(viewModel: viewModel),
      routeFrames: policyCanvasRouteFrames(placementRoutes)
    )
    let labelsOnTrunk = placementRoutes.compactMap { route in
      positions[route.id].map {
        labelFrame(center: $0, size: route.size)
      }
    }.filter { $0.intersects(verticalTrunkFrame(trunk)) }

    #expect(
      labelsOnTrunk.isEmpty,
      """
      Expected risk-family labels to leave the shared vertical departure corridor \
      x=\(trunk.x); saw \(labelsOnTrunk)
      """
    )
  }
}
