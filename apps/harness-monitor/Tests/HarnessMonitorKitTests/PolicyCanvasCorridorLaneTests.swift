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

  @Test("nearestHorizontalCorridorLane synthesises an in-band y when band has no candidate")
  func nearestLaneClampsYIntoBand() {
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

    #expect(
      preferredBand.contains(result.y),
      "Synthesised lane y=\(result.y) should fall inside the preferred band \(preferredBand)"
    )
  }

  @Test("nearestHorizontalCorridorLane gives distinct laneIndex per band when no candidate fits")
  func nearestLaneSynthesisesDistinctIndicesPerBand() {
    let candidates: [(index: Int, y: CGFloat)] = [
      (index: 0, y: 0),
      (index: 1, y: 1000),
    ]
    let firstBand: ClosedRange<CGFloat> = 200...300
    let secondBand: ClosedRange<CGFloat> = 400...500

    let firstResult = policyCanvasNearestHorizontalCorridorLane(
      desiredY: 250,
      candidates: candidates,
      preferredBand: firstBand
    )
    let secondResult = policyCanvasNearestHorizontalCorridorLane(
      desiredY: 450,
      candidates: candidates,
      preferredBand: secondBand
    )

    #expect(
      firstResult.index != secondResult.index,
      "Different out-of-band targets must produce distinct laneIndex values to keep corridor identity"
    )
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
  @Test("reflow preserving anchors seeds order from each node's own row")
  func reflowPreservingAnchorsSeedsFromOwnPosition() {
    let mode = PolicyCanvasAutomaticLayoutMode.explicitReflow(preserveManualAnchors: true)
    #expect(mode.orderSeedStrategy == .currentPosition)
  }

  @Test("reflow dropping anchors still keeps the on-screen arrangement")
  func reflowDroppingAnchorsSeedsFromOwnPosition() {
    // Whether the prior layout came from auto placement or from trusted saved
    // coordinates loaded as manual, Reformat reproduces the on-screen rows
    // instead of reshuffling them. Dropping anchors does not reset to graph order.
    let mode = PolicyCanvasAutomaticLayoutMode.explicitReflow(preserveManualAnchors: false)
    #expect(mode.orderSeedStrategy == .currentPosition)
  }

  @Test("initial load seeds order from neighbour barycenter")
  func initialLoadSeedsFromNeighborBarycenter() {
    let mode = PolicyCanvasAutomaticLayoutMode.initialLoad
    #expect(mode.orderSeedStrategy == .neighborBarycenter)
  }
}
