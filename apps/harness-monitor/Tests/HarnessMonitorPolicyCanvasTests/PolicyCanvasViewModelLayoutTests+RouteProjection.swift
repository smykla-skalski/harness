import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

extension PolicyCanvasViewModelLayoutTests {
  @Test("stale route output projects moved node endpoints for immediate edge repaint")
  func staleRouteOutputProjectsMovedNodeEndpointsForImmediateEdgeRepaint() async throws {
    let source = PolicyCanvasNode(
      id: "source",
      title: "Source",
      kind: .workflowEntry,
      position: CGPoint(x: 80, y: 120)
    )
    var target = PolicyCanvasNode(
      id: "target",
      title: "Target",
      kind: .evidenceCheck,
      position: CGPoint(x: 360, y: 120)
    )
    let edge = PolicyCanvasEdge(
      id: "edge",
      source: PolicyCanvasPortEndpoint(
        nodeID: source.id,
        portID: source.outputPorts[0].id,
        kind: .output
      ),
      target: PolicyCanvasPortEndpoint(
        nodeID: target.id,
        portID: target.inputPorts[0].id,
        kind: .input
      ),
      label: "flow"
    )
    let cachedOutput = await PolicyCanvasRouteWorker(router: PolicyCanvasVisibilityRouter())
      .compute(
        input: PolicyCanvasRouteWorkerInput(
          nodes: [source, target],
          groups: [],
          edges: [edge],
          fontScale: 1
        )
      )
    let cachedRoute = try #require(cachedOutput.routes[edge.id])
    let cachedSource = try #require(cachedRoute.points.first)
    let cachedTarget = try #require(cachedRoute.points.last)
    let cachedNodePositions = policyCanvasNodePositionsByID([source, target])
    let targetDelta = CGSize(width: 160, height: 96)
    target.position = CGPoint(
      x: target.position.x + targetDelta.width,
      y: target.position.y + targetDelta.height
    )

    let projectedOutput = policyCanvasProjectedRouteOutput(
      input: PolicyCanvasProjectedRouteInput(
        cachedOutput: cachedOutput,
        cachedNodePositionsByID: cachedNodePositions,
        currentNodes: [source, target],
        groups: [],
        edges: [edge],
        fontScale: 1
      )
    )
    let projectedRoute = try #require(projectedOutput.routes[edge.id])
    let projectedSource = try #require(projectedRoute.points.first)
    let projectedTarget = try #require(projectedRoute.points.last)

    #expect(projectedSource == cachedSource)
    #expect(
      projectedTarget
        == CGPoint(
          x: cachedTarget.x + targetDelta.width,
          y: cachedTarget.y + targetDelta.height
        ))
    #expect(projectedOutput.signature != cachedOutput.signature)
  }

  @Test("stale route projection preserves cached interior corridor")
  func staleRouteProjectionPreservesCachedInteriorCorridor() {
    let source = PolicyCanvasNode(
      id: "source",
      title: "Source",
      kind: .workflowEntry,
      position: CGPoint(x: 80, y: 120)
    )
    var target = PolicyCanvasNode(
      id: "target",
      title: "Target",
      kind: .evidenceCheck,
      position: CGPoint(x: 520, y: 240)
    )
    let edge = PolicyCanvasEdge(
      id: "edge",
      source: PolicyCanvasPortEndpoint(
        nodeID: source.id,
        portID: source.outputPorts[0].id,
        kind: .output
      ),
      target: PolicyCanvasPortEndpoint(
        nodeID: target.id,
        portID: target.inputPorts[0].id,
        kind: .input
      ),
      label: "flow"
    )
    let cachedPoints = [
      CGPoint(x: 164, y: 168),
      CGPoint(x: 220, y: 168),
      CGPoint(x: 220, y: 360),
      CGPoint(x: 412, y: 360),
      CGPoint(x: 412, y: 288),
      CGPoint(x: 520, y: 288),
    ]
    let cachedRoute = PolicyCanvasEdgeRoute(
      points: cachedPoints,
      labelPosition: PolicyCanvasVisibilityRouter.labelPosition(for: cachedPoints)
    )
    let cachedBounds = polylineBounds(cachedPoints)
    let cachedOutput = PolicyCanvasRouteWorkerOutput(
      routes: [edge.id: cachedRoute],
      labelPositions: [:],
      portVisibility: [:],
      portMarkerLayout: .empty,
      visibleBounds: cachedBounds,
      contentSize: cachedBounds.size,
      accessibilityEdgeLabelsByID: [:],
      accessibilityNodeEntries: [],
      accessibilityEdgeEntries: [],
      nodeAccessibilityValuesByID: [:],
      connectTargetsByNodeID: [:]
    )
    let cachedNodePositions = policyCanvasNodePositionsByID([source, target])
    let targetDelta = CGSize(width: 24, height: 64)
    target.position.x += targetDelta.width
    target.position.y += targetDelta.height

    let projectedOutput = policyCanvasProjectedRouteOutput(
      input: PolicyCanvasProjectedRouteInput(
        cachedOutput: cachedOutput,
        cachedNodePositionsByID: cachedNodePositions,
        currentNodes: [source, target],
        groups: [],
        edges: [edge],
        fontScale: 1
      )
    )
    guard let projectedRoute = projectedOutput.routes[edge.id] else {
      Issue.record("Expected projected route for \(edge.id)")
      return
    }

    #expect(projectedRoute.points.contains(CGPoint(x: 220, y: 360)))
    #expect(projectedRoute.points.contains(CGPoint(x: 412, y: 360)))
    #expect(projectedRoute.points.last == CGPoint(x: 544, y: 352))
    #expect(polylineBounds(projectedRoute.points).maxX <= cachedBounds.maxX + targetDelta.width)
  }

  @Test("grouped endpoint routes keep group titles but not group bodies as obstacles")
  func groupedEndpointRoutesKeepGroupTitlesAsObstacles() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(
      document: PreviewFixtures.policyCanvasPipelineDocument(),
      simulation: nil,
      audit: nil
    )

    guard let edge = viewModel.edges.first(where: { $0.id == "edge:default" }),
      let source = viewModel.portAnchor(for: edge.source),
      let target = viewModel.portAnchor(for: edge.target),
      let mergeGroup = viewModel.group("merge")
    else {
      Issue.record("Expected default graph anchors and merge group")
      return
    }

    let obstacles = viewModel.routingObstacles(source: source, target: target)
    let titleFrame = policyCanvasGroupTitleFrames([mergeGroup])[0]

    #expect(obstacles.contains(titleFrame))
    #expect(!obstacles.contains(mergeGroup.frame))
  }

  private func polylineBounds(_ points: [CGPoint]) -> CGRect {
    guard let first = points.first else {
      return .null
    }
    return points.dropFirst().reduce(into: CGRect(origin: first, size: .zero)) { partial, point in
      partial = partial.union(CGRect(origin: point, size: .zero))
    }
  }
}
