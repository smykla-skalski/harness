import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas

@Suite("Policy canvas screenshot routing regressions")
@MainActor
struct PolicyCanvasRoutingScreenshotRegressionTests {
  @Test("default route uses preferred vertical corridor")
  func defaultRouteUsesPreferredVerticalCorridor() {
    assertRouteUsesPreferredVerticalCorridor("edge:default")
  }

  @Test("mutate route uses preferred vertical corridor")
  func mutateRouteUsesPreferredVerticalCorridor() {
    assertRouteUsesPreferredVerticalCorridor("edge:mutate")
  }

  @Test("unsafe route uses preferred vertical corridor")
  func unsafeRouteUsesPreferredVerticalCorridor() {
    assertRouteUsesPreferredVerticalCorridor("edge:unsafe")
  }

  @Test("risk-high route uses preferred vertical corridor")
  func riskHighRouteUsesPreferredVerticalCorridor() {
    assertRouteUsesPreferredVerticalCorridor("edge:risk-high")
  }

  @Test("risk-low route uses preferred vertical corridor")
  func riskLowRouteUsesPreferredVerticalCorridor() {
    assertRouteUsesPreferredVerticalCorridor("edge:risk-low")
  }

  @Test("risk-missing route uses preferred vertical corridor")
  func riskMissingRouteUsesPreferredVerticalCorridor() {
    assertRouteUsesPreferredVerticalCorridor("edge:risk-missing")
  }

  @Test("default graph inter-group corridor hints stay near target node bands")
  func defaultGraphInterGroupCorridorHintsStayNearTargetNodeBands() {
    let (viewModel, _) = defaultDisplayedRoutes()
    guard let routingHints = viewModel.routingHints else {
      Issue.record("Expected routing hints for the default policy graph")
      return
    }

    for edgeID in Self.targetBandEdgeIDs {
      guard
        let edge = viewModel.edges.first(where: { $0.id == edgeID }),
        let targetNode = viewModel.node(edge.target.nodeID),
        let hint = routingHints.edgeHint(for: edgeID)
      else {
        Issue.record("Expected target node and corridor hint for \(edgeID)")
        return
      }
      let targetFrame = CGRect(origin: targetNode.position, size: PolicyCanvasLayout.nodeSize)
      let targetBand = (targetFrame.minY - (PolicyCanvasLayout.gridSize * 3))...targetFrame.maxY

      #expect(
        hint.horizontalLaneY >= targetBand.lowerBound,
        "\(edgeID) horizontal hint \(hint.horizontalLaneY) should stay near target-local band \(targetBand)"
      )
      #expect(
        hint.horizontalLaneY <= targetBand.upperBound,
        "\(edgeID) horizontal hint \(hint.horizontalLaneY) should stay near target-local band \(targetBand)"
      )
    }
  }

  @Test("default graph action-to-merge route uses a target-local vertical corridor")
  func defaultGraphActionToMergeRouteUsesATargetLocalVerticalCorridor() {
    let (viewModel, routes) = defaultDisplayedRoutes()
    guard
      let edge = viewModel.edges.first(where: { $0.id == "edge:merge" }),
      let targetNode = viewModel.node(edge.target.nodeID),
      let route = routes[edge.id],
      let hint = viewModel.routingHints?.edgeHint(for: edge.id),
      let dominantLaneX = policyCanvasDominantVerticalLaneCoordinate(route),
      let hintLaneX = hint.verticalLaneX
    else {
      Issue.record("Expected edge:merge route, target node, and vertical corridor hint")
      return
    }

    let targetFrame = CGRect(origin: targetNode.position, size: PolicyCanvasLayout.nodeSize)
    let preferredBand =
      (targetFrame.minX - (PolicyCanvasLayout.gridSize * 3))...targetFrame.minX

    #expect(
      preferredBand.contains(hintLaneX),
      "edge:merge hint x \(hintLaneX) should stay in target-local band \(preferredBand)"
    )
    #expect(
      preferredBand.contains(dominantLaneX),
      """
      edge:merge vertical lane \(dominantLaneX) should stay in target-local band \
      \(preferredBand); route \(route.points)
      """
    )
  }

  @Test("default graph default route adds a target-local terminal handoff")
  func defaultGraphDefaultRouteAddsATargetLocalTerminalHandoff() {
    let (viewModel, routes) = defaultPreparedDisplayedRoutes()
    guard
      let edge = viewModel.edges.first(where: { $0.id == "edge:default" }),
      let targetNode = viewModel.node(edge.target.nodeID),
      let route = routes[edge.id],
      let terminalHandoff = finalHorizontalSegmentBeforeTarget(route)
    else {
      Issue.record(
        "Expected edge:default route, target node, and final target-local horizontal handoff")
      return
    }

    let targetFrame = CGRect(origin: targetNode.position, size: PolicyCanvasLayout.nodeSize)
    let preferredBand =
      (targetFrame.minY - (PolicyCanvasLayout.gridSize * 3))...targetFrame.maxY

    #expect(
      preferredBand.contains(terminalHandoff.start.y),
      """
      edge:default terminal handoff y \(terminalHandoff.start.y) should stay in \
      target-local band \(preferredBand); route \(route.points)
      """
    )
    #expect(
      terminalHandoff.length >= PolicyCanvasLayout.gridSize * 4,
      """
      edge:default should expose a substantial target-local handoff \
      before default-allow; route \(route.points)
      """
    )
  }

  @Test("default graph side-port routes approach without a terminal jog")
  func defaultGraphSidePortRoutesApproachWithoutATerminalJog() {
    let (viewModel, routes) = defaultDisplayedRoutes()
    // A route entering a leading/trailing port must arrive head-on: a single
    // straight horizontal at the port's Y. When the corridor descends to a lane
    // one grid off the port center, the tail degrades into an H-V-H stair-step
    // (corridor-exit horizontal, a short vertical jog, then the port stub). That
    // reads on screen as "the edge ends immediately after turning right". The
    // jog is only an artifact when a vertical precedes it and can absorb the
    // reconcile, so the pattern needs at least five points; a two-port Z whose
    // first leg is the source departure (no leading vertical) is legitimate.
    let maxReconcileJog = PolicyCanvasLayout.nodeSize.height
    for edge in viewModel.edges {
      guard let route = routes[edge.id], route.points.count >= 5 else { continue }
      let points = route.points
      let target = points[points.count - 1]
      let stubStart = points[points.count - 2]
      let beforeStub = points[points.count - 3]
      let beforeJog = points[points.count - 4]
      // Final approach into a side port is a horizontal stub.
      guard abs(stubStart.y - target.y) < 0.5, abs(stubStart.x - target.x) > 0.5 else {
        continue
      }
      // Penultimate segment is a vertical jog into the stub.
      guard abs(beforeStub.x - stubStart.x) < 0.5, abs(beforeStub.y - stubStart.y) > 0.5 else {
        continue
      }
      // The jog sits between two horizontals, the earlier of which is fed by a
      // vertical corridor that could have descended straight to the port.
      guard abs(beforeStub.y - beforeJog.y) < 0.5, abs(beforeStub.x - beforeJog.x) > 0.5 else {
        continue
      }
      let jog = abs(beforeStub.y - stubStart.y)
      #expect(
        jog > maxReconcileJog,
        """
        edge \(edge.id) jogs \(jog)pt right before its side-port approach \
        instead of arriving straight; route \(points)
        """
      )
    }
  }

  // The four merge-deny fail edges used to fan into separate rails, so a pair of
  // tests guarded against them collapsing onto one shared horizontal bus/trunk
  // (the collision the user flagged) and against the upper merge-to-terminal
  // routes piling onto that bus. The fold makes the fail family one merged wire
  // by design - there is no longer a multi-edge bus to collapse onto - so those
  // guards are obsolete. The single merged wire is covered by
  // PolicyCanvasMergedFanInTests and the MergeDeny clean-wire test; the upper
  // family's per-target lanes by the risk corridor-band test below.

  @Test("default graph action-terminal routes resolve to per-target horizontal corridor bands")
  func defaultGraphActionTerminalRoutesResolveToPerTargetHorizontalCorridorBands() {
    let (viewModel, _) = defaultDisplayedRoutes()
    guard let hints = viewModel.routingHints else {
      Issue.record("Expected routing hints for the default policy graph")
      return
    }
    for edgeID in Self.actionTerminalEdgeIDs {
      guard
        let edge = viewModel.edges.first(where: { $0.id == edgeID }),
        let targetNode = viewModel.node(edge.target.nodeID),
        let hint = hints.edgeHint(for: edgeID)
      else {
        Issue.record("Expected action-terminal edge, target node, and hint for \(edgeID)")
        return
      }
      let targetFrame = CGRect(origin: targetNode.position, size: PolicyCanvasLayout.nodeSize)
      let targetBand = (targetFrame.minY - (PolicyCanvasLayout.gridSize * 3))...targetFrame.maxY
      #expect(
        targetBand.contains(hint.horizontalLaneY),
        "\(edgeID) hint y=\(hint.horizontalLaneY) should fall inside its own target band \(targetBand)"
      )
    }
  }

  @Test("default graph risk routes resolve to per-target horizontal corridor bands")
  func defaultGraphRiskRoutesResolveToPerTargetHorizontalCorridorBands() {
    let (viewModel, _) = defaultDisplayedRoutes()
    guard let hints = viewModel.routingHints else {
      Issue.record("Expected routing hints for the default policy graph")
      return
    }
    for edgeID in Self.riskFamilyEdgeIDs {
      guard
        let edge = viewModel.edges.first(where: { $0.id == edgeID }),
        let targetNode = viewModel.node(edge.target.nodeID),
        let hint = hints.edgeHint(for: edgeID)
      else {
        Issue.record("Expected risk edge, target node, and hint for \(edgeID)")
        return
      }
      let targetFrame = CGRect(origin: targetNode.position, size: PolicyCanvasLayout.nodeSize)
      let targetBand = (targetFrame.minY - (PolicyCanvasLayout.gridSize * 3))...targetFrame.maxY
      #expect(
        targetBand.contains(hint.horizontalLaneY),
        "\(edgeID) hint y=\(hint.horizontalLaneY) should fall inside its own target band \(targetBand)"
      )
    }
  }
}

extension PolicyCanvasRoutingScreenshotRegressionTests {
  static let actionTerminalEdgeIDs = [
    "edge:default",
    "edge:mutate",
    "edge:unsafe",
  ]

  static let riskFamilyEdgeIDs = [
    "edge:risk-high",
    "edge:risk-low",
    "edge:risk-missing",
  ]

  static let mergeToTerminalLabelEdgeIDs = [
    "edge:risk-high",
    "edge:risk-low",
    "edge:risk-missing",
    "edge:evidence-consensus",
    "edge:evidence-missing",
  ]

  static let middleMergeToTerminalEdgeIDs = [
    "edge:evidence-consensus",
    "edge:evidence-missing",
    "edge:risk-missing",
  ]

  // The merged fail wire is a folded construct with no per-edge layout routing
  // hint (hints are computed for the unfolded daemon edges), so it is not in the
  // corridor-hint band check; its routing is covered by the MergeDeny and
  // interiors-avoid-node-bodies tests instead.
  static let targetBandEdgeIDs = [
    "edge:default",
    "edge:risk-high",
    "edge:risk-low",
    "edge:risk-missing",
    "edge:evidence-consensus",
    "edge:evidence-missing",
  ]

}
