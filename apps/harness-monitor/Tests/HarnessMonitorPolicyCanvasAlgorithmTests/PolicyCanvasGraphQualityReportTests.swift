import CoreGraphics
import Foundation
import Testing

@testable import HarnessMonitorPolicyCanvasAlgorithms

struct PolicyCanvasGraphQualityReportTests {
  private func endpoint(
    _ node: String,
    _ port: String,
    _ kind: PolicyCanvasPortKind
  ) -> PolicyCanvasPortEndpoint {
    PolicyCanvasPortEndpoint(nodeID: node, portID: port, kind: kind)
  }

  private func edge(
    _ id: String,
    source: PolicyCanvasPortEndpoint,
    target: PolicyCanvasPortEndpoint,
    label: String = ""
  ) -> PolicyCanvasEdge {
    PolicyCanvasEdge(id: id, source: source, target: target, label: label)
  }

  private func route(_ points: [CGPoint], label: CGPoint = .zero) -> PolicyCanvasEdgeRoute {
    PolicyCanvasEdgeRoute(points: points, labelPosition: label)
  }

  private func measure(
    frames: [String: CGRect] = [:],
    titles: [(id: String, frame: CGRect)] = [],
    edges: [PolicyCanvasEdge] = [],
    routes: [String: PolicyCanvasEdgeRoute] = [:]
  ) -> PolicyCanvasGraphQualityReport {
    policyCanvasMeasureGraphQuality(
      nodeFramesByID: frames,
      groupTitleFrames: titles,
      edges: edges,
      routes: routes
    )
  }

  @Test func emptyGraphProducesEmptyReport() {
    let report = measure()
    #expect(report.portSpacing.isEmpty)
    #expect(report.corridors.isEmpty)
    #expect(report.crossings.isEmpty)
    #expect(report.bodyHits.isEmpty)
    #expect(report.longEdges.isEmpty)
    #expect(report.labels.isEmpty)
    #expect(report.nodeOverlaps.isEmpty)
  }

  @Test func overlappingPortMarkersAreFlagged() {
    let frames = [
      "n1": CGRect(x: 0, y: 0, width: 168, height: 96),
      "n2": CGRect(x: 400, y: 0, width: 168, height: 96),
    ]
    let edges = [
      edge("ea", source: endpoint("n1", "output-a", .output), target: endpoint("n2", "input-a", .input)),
      edge("eb", source: endpoint("n1", "output-b", .output), target: endpoint("n2", "input-b", .input)),
    ]
    let routes = [
      "ea": route([CGPoint(x: 168, y: 30), CGPoint(x: 400, y: 30)]),
      "eb": route([CGPoint(x: 168, y: 40), CGPoint(x: 400, y: 70)]),
    ]
    let overlaps = measure(frames: frames, edges: edges, routes: routes)
      .portSpacing.filter { $0.kind == .overlap }
    #expect(overlaps.count == 1)
    #expect(overlaps.first?.nodeID == "n1")
    #expect(overlaps.first?.side == .trailing)
  }

  @Test func tooClosePortMarkersAreWarned() {
    let frames = [
      "n1": CGRect(x: 0, y: 0, width: 168, height: 96),
      "n2": CGRect(x: 400, y: 0, width: 168, height: 96),
    ]
    let edges = [
      edge("ea", source: endpoint("n1", "output-a", .output), target: endpoint("n2", "input-a", .input)),
      edge("eb", source: endpoint("n1", "output-b", .output), target: endpoint("n2", "input-b", .input)),
    ]
    let routes = [
      "ea": route([CGPoint(x: 168, y: 20), CGPoint(x: 400, y: 30)]),
      "eb": route([CGPoint(x: 168, y: 50), CGPoint(x: 400, y: 50)]),
    ]
    let report = measure(frames: frames, edges: edges, routes: routes)
    #expect(report.portSpacing.contains { $0.kind == .tooClose })
    #expect(report.portSpacing.allSatisfy { $0.kind != .overlap })
  }

  @Test func detachedPortMarkerIsFlagged() {
    let frames = ["n1": CGRect(x: 0, y: 0, width: 168, height: 96)]
    let edges = [edge("ea", source: endpoint("n1", "output-a", .output), target: endpoint("n2", "input-a", .input))]
    let routes = ["ea": route([CGPoint(x: 500, y: 500), CGPoint(x: 600, y: 500)])]
    let report = measure(frames: frames, edges: edges, routes: routes)
    #expect(report.portSpacing.contains { $0.kind == .detached })
  }

  @Test func collinearCorridorReuseIsFlagged() {
    let edges = [
      edge("a", source: endpoint("s1", "o", .output), target: endpoint("t1", "i", .input)),
      edge("b", source: endpoint("s2", "o", .output), target: endpoint("t2", "i", .input)),
    ]
    let routes = [
      "a": route([
        CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 100), CGPoint(x: 300, y: 100), CGPoint(x: 300, y: 200),
      ]),
      "b": route([
        CGPoint(x: 50, y: 0), CGPoint(x: 50, y: 100), CGPoint(x: 350, y: 100), CGPoint(x: 350, y: 200),
      ]),
    ]
    let report = measure(edges: edges, routes: routes)
    #expect(report.corridors.contains { $0.kind == .collinear })
  }

  @Test func properCrossingIsFlagged() {
    let edges = [
      edge("a", source: endpoint("s1", "o", .output), target: endpoint("t1", "i", .input)),
      edge("b", source: endpoint("s2", "o", .output), target: endpoint("t2", "i", .input)),
    ]
    let routes = [
      "a": route([CGPoint(x: 0, y: 100), CGPoint(x: 200, y: 100)]),
      "b": route([CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 200)]),
    ]
    let report = measure(edges: edges, routes: routes)
    #expect(report.crossings.count == 1)
    #expect(report.crossings.first?.sharesEndpointNode == false)
  }

  @Test func routeThroughForeignNodeBodyIsFlagged() {
    let frames = ["blocker": CGRect(x: 80, y: 80, width: 40, height: 40)]
    let edges = [edge("a", source: endpoint("s1", "o", .output), target: endpoint("t1", "i", .input))]
    let routes = ["a": route([CGPoint(x: 0, y: 100), CGPoint(x: 200, y: 100)])]
    let report = measure(frames: frames, edges: edges, routes: routes)
    #expect(report.bodyHits.count == 1)
    #expect(report.bodyHits.first?.obstacleID == "blocker")
  }

  @Test func crossCanvasLongEdgeIsFlagged() {
    let edges = [edge("a", source: endpoint("s1", "o", .output), target: endpoint("t1", "i", .input))]
    let routes = ["a": route([CGPoint(x: 0, y: 0), CGPoint(x: 600, y: 0)])]
    let report = measure(edges: edges, routes: routes)
    #expect(report.longEdges.count == 1)
    #expect((report.longEdges.first?.horizontalSpan ?? 0) >= 504)
  }

  @Test func overlappingLabelsAreFlagged() {
    let edges = [
      edge("a", source: endpoint("s1", "o", .output), target: endpoint("t1", "i", .input), label: "alpha"),
      edge("b", source: endpoint("s2", "o", .output), target: endpoint("t2", "i", .input), label: "beta"),
    ]
    let routes = [
      "a": route([CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100)], label: CGPoint(x: 150, y: 100)),
      "b": route([CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100)], label: CGPoint(x: 150, y: 100)),
    ]
    let report = measure(edges: edges, routes: routes)
    #expect(report.labels.contains { $0.kind == .overlap })
  }

  @Test func overlappingNodeBodiesAreFlagged() {
    let frames = [
      "n1": CGRect(x: 0, y: 0, width: 168, height: 96),
      "n2": CGRect(x: 100, y: 0, width: 168, height: 96),
    ]
    let report = measure(frames: frames)
    #expect(report.nodeOverlaps.count == 1)
  }

  @Test func unnecessaryDetourIsFlagged() {
    let edges = [edge("a", source: endpoint("s1", "o", .output), target: endpoint("t1", "i", .input))]
    // Straight path would be 300 wide; this route dips 200 down and back up,
    // so the route length is 700 against an ideal of 300 - excess 400.
    let routes = [
      "a": route([
        CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 200), CGPoint(x: 300, y: 200), CGPoint(x: 300, y: 0),
      ])
    ]
    let report = measure(edges: edges, routes: routes)
    #expect(report.detours.count == 1)
    #expect(report.detours.first?.edgeID == "a")
    #expect((report.detours.first?.excess ?? 0) == 400)
  }

  @Test func monotoneRouteHasNoDetour() {
    let edges = [edge("a", source: endpoint("s1", "o", .output), target: endpoint("t1", "i", .input))]
    // L-shaped and monotone toward the target: route length equals the ideal.
    let routes = ["a": route([CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 120), CGPoint(x: 200, y: 120)])]
    #expect(measure(edges: edges, routes: routes).detours.isEmpty)
  }

  @Test func excessiveNodeDistanceIsFlagged() {
    let frames = [
      "n1": CGRect(x: 0, y: 0, width: 168, height: 96),
      "n2": CGRect(x: 700, y: 0, width: 168, height: 96),
    ]
    let edges = [edge("a", source: endpoint("n1", "o", .output), target: endpoint("n2", "i", .input))]
    let report = measure(frames: frames, edges: edges)
    #expect(report.nodeDistance.count == 1)
    #expect(report.nodeDistance.first?.sourceID == "n1")
    #expect(report.nodeDistance.first?.targetID == "n2")
    #expect((report.nodeDistance.first?.distance ?? 0) == 532)
  }

  @Test func adjacentNodesAreNotTooFar() {
    let frames = [
      "n1": CGRect(x: 0, y: 0, width: 168, height: 96),
      "n2": CGRect(x: 308, y: 0, width: 168, height: 96),
    ]
    let edges = [edge("a", source: endpoint("n1", "o", .output), target: endpoint("n2", "i", .input))]
    #expect(measure(frames: frames, edges: edges).nodeDistance.isEmpty)
  }

  @Test func reportIsDeterministic() {
    let frames = [
      "n1": CGRect(x: 0, y: 0, width: 168, height: 96),
      "n2": CGRect(x: 400, y: 0, width: 168, height: 96),
    ]
    let edges = [
      edge("ea", source: endpoint("n1", "output-a", .output), target: endpoint("n2", "input-a", .input)),
      edge("eb", source: endpoint("n1", "output-b", .output), target: endpoint("n2", "input-b", .input)),
    ]
    let routes = [
      "ea": route([CGPoint(x: 168, y: 30), CGPoint(x: 400, y: 30)]),
      "eb": route([CGPoint(x: 168, y: 40), CGPoint(x: 400, y: 70)]),
    ]
    #expect(
      measure(frames: frames, edges: edges, routes: routes)
        == measure(frames: frames, edges: edges, routes: routes)
    )
  }
}
