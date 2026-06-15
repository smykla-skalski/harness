import CoreGraphics
import Testing

@testable import HarnessMonitorPolicyCanvasAlgorithms

/// Label-vs-edge and label-vs-turn detection: a label box that lands on top of a
/// wire other than the one it names, and a label box that overlaps or crowds a
/// route bend. Both read as readability defects the placement should avoid.
struct PolicyCanvasLabelEdgeAndTurnTests {
  /// Node frames parked far from the label boxes under test so the only signals
  /// that can fire are the label-edge and label-turn ones, never on-body.
  private let frames: [String: CGRect] = [
    "os": CGRect(x: 2000, y: 2000, width: 168, height: 96),
    "ot": CGRect(x: 2400, y: 2000, width: 168, height: 96),
    "fs": CGRect(x: 2000, y: 2400, width: 168, height: 96),
    "ft": CGRect(x: 2400, y: 2400, width: 168, height: 96),
  ]

  private func edge(_ id: String, source: String, target: String, label: String) -> PolicyCanvasEdge {
    PolicyCanvasEdge(
      id: id,
      source: PolicyCanvasPortEndpoint(nodeID: source, portID: "out", kind: .output),
      target: PolicyCanvasPortEndpoint(nodeID: target, portID: "in", kind: .input),
      label: label
    )
  }

  private func route(_ points: [CGPoint], label: CGPoint) -> PolicyCanvasEdgeRoute {
    PolicyCanvasEdgeRoute(points: points, labelPosition: label)
  }

  private func report(
    edges: [PolicyCanvasEdge],
    routes: [String: PolicyCanvasEdgeRoute]
  ) -> PolicyCanvasGraphQualityReport {
    policyCanvasMeasureGraphQuality(
      nodeFramesByID: frames,
      groupTitleFrames: [],
      edges: edges,
      routes: routes
    )
  }

  @Test func labelOverForeignWireIsFlagged() {
    // owner runs horizontal through its own label; foreign runs vertical through
    // the same label box - the label sits on a wire it does not name.
    let owner = edge("owner", source: "os", target: "ot", label: "resolve")
    let foreign = edge("foreign", source: "fs", target: "ft", label: "")
    let result = report(
      edges: [owner, foreign],
      routes: [
        "owner": route([CGPoint(x: 0, y: 300), CGPoint(x: 400, y: 300)], label: CGPoint(x: 200, y: 300)),
        "foreign": route([CGPoint(x: 200, y: 250), CGPoint(x: 200, y: 360)], label: .zero),
      ]
    )
    #expect(result.count(for: .labelOnEdge) == 1)
    let violation = try! #require(result.labels.first { $0.kind == .crossesEdge })
    #expect(violation.edgeID == "owner")
    #expect(violation.otherID == "foreign")
  }

  @Test func labelOnlyOverOwnWireIsClean() {
    // The owner's own wire passes through its label - that is expected, not a hit.
    let owner = edge("owner", source: "os", target: "ot", label: "resolve")
    let result = report(
      edges: [owner],
      routes: [
        "owner": route([CGPoint(x: 0, y: 300), CGPoint(x: 400, y: 300)], label: CGPoint(x: 200, y: 300)),
      ]
    )
    #expect(result.count(for: .labelOnEdge) == 0)
  }

  @Test func foreignWireClearOfLabelIsClean() {
    let owner = edge("owner", source: "os", target: "ot", label: "resolve")
    let foreign = edge("foreign", source: "fs", target: "ft", label: "")
    let result = report(
      edges: [owner, foreign],
      routes: [
        "owner": route([CGPoint(x: 0, y: 300), CGPoint(x: 400, y: 300)], label: CGPoint(x: 200, y: 300)),
        "foreign": route([CGPoint(x: 900, y: 250), CGPoint(x: 900, y: 360)], label: .zero),
      ]
    )
    #expect(result.count(for: .labelOnEdge) == 0)
  }

  @Test func labelOnOwnTurnIsFlagged() {
    // The owner bends at its own label position - the label crowds the corner.
    let owner = edge("owner", source: "os", target: "ot", label: "blocked")
    let result = report(
      edges: [owner],
      routes: [
        "owner": route(
          [CGPoint(x: 0, y: 300), CGPoint(x: 200, y: 300), CGPoint(x: 200, y: 500)],
          label: CGPoint(x: 200, y: 300)
        ),
      ]
    )
    #expect(result.count(for: .labelNearTurn) == 1)
    let violation = try! #require(result.labels.first { $0.kind == .nearTurn })
    #expect(violation.edgeID == "owner")
  }

  @Test func labelFarFromAnyTurnIsClean() {
    // The bend is at the far end, well past the label box clearance.
    let owner = edge("owner", source: "os", target: "ot", label: "x")
    let result = report(
      edges: [owner],
      routes: [
        "owner": route(
          [CGPoint(x: 0, y: 300), CGPoint(x: 400, y: 300), CGPoint(x: 400, y: 500)],
          label: CGPoint(x: 100, y: 300)
        ),
      ]
    )
    #expect(result.count(for: .labelNearTurn) == 0)
  }

  @Test func labelNearForeignTurnIsFlagged() {
    // A neighbor's bend lands next to the label box - the label crowds a corner
    // that is not even on its own wire.
    let owner = edge("owner", source: "os", target: "ot", label: "recognized")
    let foreign = edge("foreign", source: "fs", target: "ft", label: "")
    let result = report(
      edges: [owner, foreign],
      routes: [
        "owner": route([CGPoint(x: 0, y: 300), CGPoint(x: 400, y: 300)], label: CGPoint(x: 200, y: 300)),
        "foreign": route(
          [CGPoint(x: 220, y: 200), CGPoint(x: 220, y: 305), CGPoint(x: 400, y: 305)],
          label: .zero
        ),
      ]
    )
    let nearTurn = try! #require(result.labels.first { $0.kind == .nearTurn })
    #expect(nearTurn.otherID == "foreign")
  }
}
