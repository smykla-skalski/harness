import AppKit
import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

extension PolicyCanvasRoutingTests {
  @Test("display label placement separates labels along the route")
  func displayLabelPlacementSeparatesLabelsAlongRoute() {
    let labelSize = CGSize(width: 56, height: PolicyCanvasLayout.edgeLabelHeight)
    let positions = policyCanvasResolvedLabelPositions(
      routes: [
        (
          id: "edge-a",
          route: PolicyCanvasEdgeRoute(
            points: [CGPoint(x: 0, y: 0), CGPoint(x: 360, y: 0)],
            labelPosition: CGPoint(x: 110, y: 100)
          )
        ),
        (
          id: "edge-b",
          route: PolicyCanvasEdgeRoute(
            points: [CGPoint(x: 20, y: 0), CGPoint(x: 380, y: 0)],
            labelPosition: CGPoint(x: 110, y: 100)
          )
        ),
      ],
      nodeFrames: [],
      labelSize: labelSize
    )

    guard let first = positions["edge-a"], let second = positions["edge-b"] else {
      Issue.record("expected both label positions")
      return
    }
    #expect(first.y == 0)
    #expect(second.y == 0)
    #expect(
      !edgeLabelFrame(first, size: labelSize).intersects(
        edgeLabelFrame(second, size: labelSize)))
  }

  @Test("display label placement keeps fallback on route when lanes are blocked")
  func displayLabelPlacementKeepsFallbackOnRouteWhenLanesAreBlocked() {
    let base = CGPoint(x: 110, y: 100)
    let positions = policyCanvasResolvedLabelPositions(
      routes: [
        (
          id: "edge-a",
          route: PolicyCanvasEdgeRoute(
            points: [CGPoint(x: 0, y: 0), CGPoint(x: 220, y: 0)],
            labelPosition: base
          )
        )
      ],
      nodeFrames: [
        CGRect(x: 0, y: -200, width: 220, height: 400)
      ],
      labelSize: CGSize(
        width: PolicyCanvasLayout.edgeLabelMaxWidth,
        height: PolicyCanvasLayout.edgeLabelHeight
      )
    )

    guard let position = positions["edge-a"] else {
      Issue.record("expected label position")
      return
    }
    #expect(position.x == 110)
    #expect(position.y == 0)
  }

  @Test("display label placement avoids other route segments")
  func displayLabelPlacementAvoidsOtherRouteSegments() {
    let base = CGPoint(x: 180, y: 100)
    let labelSize = CGSize(width: 56, height: PolicyCanvasLayout.edgeLabelHeight)
    let positions = policyCanvasResolvedLabelPositions(
      routes: [
        (
          id: "edge-a",
          route: PolicyCanvasEdgeRoute(
            points: [CGPoint(x: 0, y: 100), CGPoint(x: 360, y: 100)],
            labelPosition: base
          )
        ),
        (
          id: "edge-b",
          route: PolicyCanvasEdgeRoute(
            points: [CGPoint(x: 180, y: -60), CGPoint(x: 180, y: 260)],
            labelPosition: CGPoint(x: 110, y: 180)
          )
        ),
      ],
      nodeFrames: [],
      routeFrames: [
        "edge-b": [CGRect(x: 170, y: -60, width: 20, height: 320)]
      ],
      labelSize: labelSize
    )

    guard let position = positions["edge-a"] else {
      Issue.record("expected label position")
      return
    }
    #expect(position.x != base.x)
    #expect(position.y == base.y)
  }

  @Test("display label placement avoids route corners")
  func displayLabelPlacementAvoidsRouteCorners() {
    let labelSize = CGSize(width: 56, height: PolicyCanvasLayout.edgeLabelHeight)
    let positions = policyCanvasResolvedLabelPositions(
      routes: [
        (
          id: "edge-a",
          route: PolicyCanvasEdgeRoute(
            points: [
              CGPoint(x: 0, y: 0),
              CGPoint(x: 220, y: 0),
              CGPoint(x: 220, y: 120),
            ],
            labelPosition: CGPoint(x: 216, y: 0)
          )
        )
      ],
      nodeFrames: [],
      labelSize: labelSize
    )

    guard let position = positions["edge-a"] else {
      Issue.record("expected label position")
      return
    }
    #expect(position.y == 0)
    #expect(position.x <= 140)
  }

  @Test("display label placement avoids unlabeled blocking routes")
  func displayLabelPlacementAvoidsUnlabeledBlockingRoutes() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.nodes = []
    viewModel.groups = []
    viewModel.edges = [
      PolicyCanvasEdge(
        id: "edge-a",
        source: PolicyCanvasPortEndpoint(nodeID: "source-a", portID: "out", kind: .output),
        target: PolicyCanvasPortEndpoint(nodeID: "target-a", portID: "in", kind: .input),
        label: "evidence failure",
        condition: "checks_failed",
        pinnedPortSide: true,
        kind: .error,
        isAnimated: false
      ),
      PolicyCanvasEdge(
        id: "edge-b",
        source: PolicyCanvasPortEndpoint(nodeID: "source-b", portID: "out", kind: .output),
        target: PolicyCanvasPortEndpoint(nodeID: "target-b", portID: "in", kind: .input),
        label: "",
        condition: "always",
        pinnedPortSide: true,
        kind: .flow,
        isAnimated: false
      ),
    ]
    let routes = [
      "edge-a": PolicyCanvasEdgeRoute(
        points: [CGPoint(x: 0, y: 100), CGPoint(x: 360, y: 100)],
        labelPosition: CGPoint(x: 180, y: 100)
      ),
      "edge-b": PolicyCanvasEdgeRoute(
        points: [CGPoint(x: 180, y: -40), CGPoint(x: 180, y: 240)],
        labelPosition: CGPoint(x: 180, y: 120)
      ),
    ]

    guard
      let position = policyCanvasResolvedLabelPositions(
        viewModel: viewModel,
        edges: viewModel.edges,
        routes: routes,
        fontScale: 1
      )["edge-a"]
    else {
      Issue.record("expected labelled edge position")
      return
    }

    let labelFrame = PolicyCanvasEdgeLabelMetrics(fontScale: 1).frame(
      for: "evidence failure",
      center: position
    )
    let blockingRouteFrame = CGRect(x: 170, y: -40, width: 20, height: 280)
    #expect(!labelFrame.intersects(blockingRouteFrame))
  }

  @Test("display label placement demotes shared trunks for bundled siblings")
  func displayLabelPlacementDemotesSharedTrunksForBundledSiblings() {
    let labelSize = CGSize(width: 88, height: PolicyCanvasLayout.edgeLabelHeight)
    let routes: [(id: String, route: PolicyCanvasEdgeRoute)] = [
      (
        id: "edge-a",
        route: PolicyCanvasEdgeRoute(
          points: [
            CGPoint(x: 0, y: 40),
            CGPoint(x: 96, y: 40),
            CGPoint(x: 96, y: 0),
            CGPoint(x: 420, y: 0),
            CGPoint(x: 420, y: 88),
          ],
          labelPosition: CGPoint(x: 260, y: 0)
        )
      ),
      (
        id: "edge-b",
        route: PolicyCanvasEdgeRoute(
          points: [
            CGPoint(x: 0, y: 88),
            CGPoint(x: 128, y: 88),
            CGPoint(x: 128, y: 0),
            CGPoint(x: 420, y: 0),
            CGPoint(x: 420, y: 136),
          ],
          labelPosition: CGPoint(x: 260, y: 0)
        )
      ),
      (
        id: "edge-c",
        route: PolicyCanvasEdgeRoute(
          points: [
            CGPoint(x: 0, y: 136),
            CGPoint(x: 160, y: 136),
            CGPoint(x: 160, y: 0),
            CGPoint(x: 420, y: 0),
            CGPoint(x: 420, y: 184),
          ],
          labelPosition: CGPoint(x: 260, y: 0)
        )
      ),
    ]
    let positions = policyCanvasResolvedLabelPositions(
      routes: routes,
      nodeFrames: [],
      routeFrames: policyCanvasRouteFrames(routes),
      labelSize: labelSize
    )

    let trunkLabels = positions.values.filter { abs($0.y) < 0.5 }
    #expect(trunkLabels.count <= 1)
    #expect(trunkLabels.count < positions.count)
  }
}
