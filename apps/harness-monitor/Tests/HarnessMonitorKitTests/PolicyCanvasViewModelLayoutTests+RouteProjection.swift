import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

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
}
