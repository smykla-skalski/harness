import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

@Suite("Policy canvas edge hit test - fat stroke covers polyline midpoint")
struct PolicyCanvasEdgeHitTestTests {
  @Test("Hit shape covers a point on the polyline")
  func hitShapeCoversOnRoutePoint() {
    let route = PolicyCanvasEdgeRoute(
      points: [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 100, y: 0),
        CGPoint(x: 100, y: 100),
      ],
      labelPosition: CGPoint(x: 100, y: 50)
    )
    let path = PolicyCanvasEdgeHitShape(route: route).path(in: .zero)
    // Midpoint of the first segment lies on the route.
    #expect(path.contains(CGPoint(x: 50, y: 0)))
    // Midpoint of the second segment.
    #expect(path.contains(CGPoint(x: 100, y: 50)))
  }

  @Test("Hit shape misses a point far from the polyline")
  func hitShapeMissesFarPoint() {
    let route = PolicyCanvasEdgeRoute(
      points: [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 100, y: 0),
        CGPoint(x: 100, y: 100),
      ],
      labelPosition: CGPoint(x: 100, y: 50)
    )
    let path = PolicyCanvasEdgeHitShape(route: route).path(in: .zero)
    // 50pt from the closest segment - well outside the 12pt fat stroke.
    #expect(!path.contains(CGPoint(x: 50, y: 50)))
    #expect(!path.contains(CGPoint(x: 200, y: 200)))
  }

  @Test("Fat hit area widens the hit zone to roughly 12pt")
  func hitShapeWidthIsApproximatelyTwelvePoints() {
    let route = PolicyCanvasEdgeRoute(
      points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)],
      labelPosition: CGPoint(x: 50, y: 0)
    )
    let path = PolicyCanvasEdgeHitShape(route: route).path(in: .zero)
    // ±5pt above/below the line should still hit (half of 12 minus padding).
    #expect(path.contains(CGPoint(x: 50, y: 5)))
    #expect(path.contains(CGPoint(x: 50, y: -5)))
    // ±7pt is outside the fat stroke.
    #expect(!path.contains(CGPoint(x: 50, y: 8)))
    #expect(!path.contains(CGPoint(x: 50, y: -8)))
  }

  @Test("edge hit testing does not rebuild rendered stroke paths")
  func edgeHitTestingDoesNotRebuildRenderedStrokePaths() throws {
    let source = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasInteractiveEdge.swift"
    )

    #expect(
      source.contains(
        "strokeLayer(route: renderedRoute)\n        .allowsHitTesting(false)"
      )
    )
    #expect(
      source.contains(
        """
        PolicyCanvasEdgeArrowhead(route: renderedRoute)
                .fill(arrowheadColor)
                .allowsHitTesting(false)
        """
      )
    )
    #expect(source.contains("struct PolicyCanvasEdgeHitShape: Shape"))
    #expect(!source.contains("PolicyCanvasEdgeShape(route: route)\n      .path(in: rect)"))
  }

  @Test("native pointer hit testing can select an edge route")
  @MainActor
  func nativePointerHitTestingCanSelectEdgeRoute() {
    let edge = PolicyCanvasEdge(
      id: "edge-a",
      source: PolicyCanvasPortEndpoint(nodeID: "source", portID: "out", kind: .output),
      target: PolicyCanvasPortEndpoint(nodeID: "target", portID: "in", kind: .input),
      label: "route"
    )
    let viewModel = PolicyCanvasViewModel(nodes: [], groups: [], edges: [edge])
    let route = PolicyCanvasEdgeRoute(
      points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 80)],
      labelPosition: CGPoint(x: 100, y: 40)
    )

    #expect(
      viewModel.canvasEdgeHitTarget(
        at: CGPoint(x: 45, y: 5),
        routes: [edge.id: route]
      ) == edge.id
    )
    #expect(
      viewModel.canvasEdgeHitTarget(
        at: CGPoint(x: 50, y: 12),
        routes: [edge.id: route]
      ) == nil
    )
    #expect(
      viewModel.canvasPointerHitTarget(
        at: CGPoint(x: 100, y: 35),
        routes: [edge.id: route]
      ) == .edge(edge.id)
    )
  }

  private func previewableSourceFile(named path: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitorUIPreviewable")
      .appendingPathComponent(path)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
