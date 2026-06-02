import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorPolicyCanvas

@Suite("Policy canvas crowded label stagger")
struct PolicyCanvasCrowdedLabelStaggerTests {
  @Test("duplicate-content labels each stay on their own edge")
  func duplicateLabelsStayOnTheirOwnEdges() {
    let labelSize = CGSize(width: 132, height: PolicyCanvasLayout.edgeLabelHeight)
    // Four distinct edges that happen to carry identical text. Each is a long
    // horizontal at its own y. They are keyed by unique ids, so each label must
    // land on its own route - sharing the words "evidence failure" must not pull
    // any label off its edge onto a neighbour's lane or into open space.
    let edgeYs: [CGFloat] = [200, 240, 280, 320]
    let placementRoutes = edgeYs.enumerated().map { index, edgeY in
      PolicyCanvasLabelPlacementRoute(
        id: "edge-\(index)",
        label: "evidence failure",
        route: PolicyCanvasEdgeRoute(
          points: [CGPoint(x: 360, y: edgeY), CGPoint(x: 760, y: edgeY)],
          labelPosition: CGPoint(x: 560, y: edgeY)
        ),
        size: labelSize
      )
    }

    let positions = policyCanvasResolvedLabelPositions(
      routes: placementRoutes,
      nodeFrames: [],
      routeFrames: [:]
    )

    #expect(positions.count == 4)
    for (index, edgeY) in edgeYs.enumerated() {
      guard let center = positions["edge-\(index)"] else {
        Issue.record("Expected a placed position for edge-\(index)")
        continue
      }
      #expect(
        abs(center.y - edgeY) <= labelSize.height / 2,
        "label \(index) drifted off its own horizontal edge: y \(center.y) vs edge \(edgeY)"
      )
      #expect(
        (360...760).contains(center.x),
        "label \(index) x \(center.x) left its own edge span 360...760"
      )
    }

    // Edges 40pt apart with 28pt-tall labels: each fits on its own line, so the
    // geometric collision pass keeps them from overlapping without any
    // content-based stagger.
    let frames = (0..<4).compactMap { index -> CGRect? in
      positions["edge-\(index)"].map {
        CGRect(
          x: $0.x - (labelSize.width / 2),
          y: $0.y - (labelSize.height / 2),
          width: labelSize.width,
          height: labelSize.height
        )
      }
    }
    for leftIndex in 0..<frames.count {
      for rightIndex in (leftIndex + 1)..<frames.count {
        #expect(
          !frames[leftIndex].intersects(frames[rightIndex]),
          "labels \(leftIndex) and \(rightIndex) on well-separated edges should not overlap"
        )
      }
    }
  }
}
