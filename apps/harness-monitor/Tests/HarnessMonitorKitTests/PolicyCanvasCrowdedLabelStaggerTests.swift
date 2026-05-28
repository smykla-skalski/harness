import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas crowded label stagger")
struct PolicyCanvasCrowdedLabelStaggerTests {
  @Test("four duplicate labels on a tight shared bus do not overlap after crowded fallback")
  func fourDuplicateLabelsDoNotOverlap() {
    let labelSize = CGSize(width: 132, height: PolicyCanvasLayout.edgeLabelHeight)
    let busY: CGFloat = 200
    let route = PolicyCanvasEdgeRoute(
      points: [
        CGPoint(x: 380, y: busY - 4),
        CGPoint(x: 480, y: busY - 4),
        CGPoint(x: 480, y: busY + 4),
        CGPoint(x: 580, y: busY + 4),
      ],
      labelPosition: CGPoint(x: 480, y: busY)
    )
    let denseNeighbors: [CGRect] = [
      CGRect(x: 360, y: busY - 28, width: 80, height: 56),
      CGRect(x: 520, y: busY - 28, width: 80, height: 56),
      CGRect(x: 360, y: busY - 70, width: 240, height: 32),
      CGRect(x: 360, y: busY + 38, width: 240, height: 32),
    ]

    let placementRoutes: [PolicyCanvasLabelPlacementRoute] = (1...4).map { ordinal in
      PolicyCanvasLabelPlacementRoute(
        id: "edge-\(ordinal)",
        label: "evidence failure",
        route: route,
        size: labelSize
      )
    }

    let positions = policyCanvasResolvedLabelPositions(
      routes: placementRoutes,
      nodeFrames: denseNeighbors,
      routeFrames: [:]
    )

    #expect(positions.count == 4)
    let frames = placementRoutes.compactMap { route -> CGRect? in
      guard let center = positions[route.id] else {
        return nil
      }
      return CGRect(
        x: center.x - (route.size.width / 2),
        y: center.y - (route.size.height / 2),
        width: route.size.width,
        height: route.size.height
      )
    }
    #expect(frames.count == 4)
    for leftIndex in 0..<frames.count {
      for rightIndex in (leftIndex + 1)..<frames.count {
        let left = frames[leftIndex]
        let right = frames[rightIndex]
        #expect(
          !left.intersects(right),
          "Duplicate labels \(leftIndex) and \(rightIndex) must not overlap; frames \(left) and \(right)"
        )
      }
    }
  }
}
