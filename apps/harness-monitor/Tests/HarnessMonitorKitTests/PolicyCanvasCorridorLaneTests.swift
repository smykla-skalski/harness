import SwiftUI
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas corridor lane candidates")
struct PolicyCanvasCorridorLaneTests {
  @Test("single-node fallback lanes sit outside the node's vertical extent")
  func singleNodeLanesAvoidNodeBody() {
    let nodeCenter = CGPoint(x: 100, y: 100)
    let positions = ["only": nodeCenter]
    let lanes = policyCanvasHorizontalCorridorLaneCandidates(nodePositions: positions)

    let centerY = nodeCenter.y + (PolicyCanvasLayout.nodeSize.height / 2)
    let topNodeEdge = centerY - PolicyCanvasLayout.nodeSize.height / 2
    let bottomNodeEdge = centerY + PolicyCanvasLayout.nodeSize.height / 2

    #expect(lanes.count >= 2)
    for lane in lanes {
      let insideNodeBand = lane.y > topNodeEdge && lane.y < bottomNodeEdge
      #expect(!insideNodeBand, "Lane y=\(lane.y) falls inside node body \(topNodeEdge)..<\(bottomNodeEdge)")
    }
  }

  @Test("tightly packed cluster fallback lanes go around the cluster, not through")
  func tightClusterLanesAvoidNodeBodies() {
    let positions = [
      "a": CGPoint(x: 100, y: 100),
      "b": CGPoint(x: 100, y: 120),
      "c": CGPoint(x: 100, y: 140),
    ]
    let lanes = policyCanvasHorizontalCorridorLaneCandidates(nodePositions: positions)

    let nodeBands = positions.values.map { position in
      (position.y, position.y + PolicyCanvasLayout.nodeSize.height)
    }

    #expect(!lanes.isEmpty)
    for lane in lanes {
      for band in nodeBands {
        let insideBand = lane.y > band.0 && lane.y < band.1
        #expect(!insideBand, "Lane y=\(lane.y) falls inside node band \(band.0)..<\(band.1)")
      }
    }
  }

  @Test("nearestHorizontalCorridorLane returns matching (index, y) when band has no candidate")
  func nearestLaneReturnsMatchingPair() {
    let candidates: [(index: Int, y: CGFloat)] = [
      (index: 0, y: 0),
      (index: 1, y: 100),
      (index: 2, y: 500),
    ]
    let preferredBand: ClosedRange<CGFloat> = 200...300

    let result = policyCanvasNearestHorizontalCorridorLane(
      desiredY: 250,
      candidates: candidates,
      preferredBand: preferredBand
    )

    let matchedCandidate = candidates.first { $0.index == result.index }
    #expect(matchedCandidate != nil)
    #expect(matchedCandidate?.y == result.y)
  }

  @Test("nearestHorizontalCorridorLane returns in-band candidate when one exists")
  func nearestLaneReturnsInBandCandidate() {
    let candidates: [(index: Int, y: CGFloat)] = [
      (index: 0, y: 0),
      (index: 1, y: 250),
      (index: 2, y: 500),
    ]
    let preferredBand: ClosedRange<CGFloat> = 200...300

    let result = policyCanvasNearestHorizontalCorridorLane(
      desiredY: 250,
      candidates: candidates,
      preferredBand: preferredBand
    )

    #expect(result.index == 1)
    #expect(result.y == 250)
  }
}

@Suite("Policy canvas reflow geometric seed")
struct PolicyCanvasReflowSeedTests {
  @Test("reflow preserving anchors seeds order from current geometry")
  func reflowPreservingAnchorsKeepsGeometricSeed() {
    let mode = PolicyCanvasAutomaticLayoutMode.explicitReflow(preserveManualAnchors: true)
    #expect(mode.seedsOrderHintsFromCurrentGeometry)
  }

  @Test("reflow dropping anchors uses originalIndex order")
  func reflowDroppingAnchorsDropsGeometricSeed() {
    let mode = PolicyCanvasAutomaticLayoutMode.explicitReflow(preserveManualAnchors: false)
    #expect(!mode.seedsOrderHintsFromCurrentGeometry)
  }

  @Test("initial load still uses geometric seed")
  func initialLoadStillSeedsFromGeometry() {
    let mode = PolicyCanvasAutomaticLayoutMode.initialLoad
    #expect(mode.seedsOrderHintsFromCurrentGeometry)
  }
}
