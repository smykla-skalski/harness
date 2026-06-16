import CoreGraphics
import Testing

@testable import HarnessMonitorPolicyCanvasAlgorithms

/// The label-placement pass moves a label off its route midpoint to a clearer
/// spot, and the renderer draws it there (`labelPositions[edge.id]`). The quality
/// measure must box the label at that same resolved spot, not at the raw route
/// midpoint - otherwise every overlay mark lands offset from the label it flags.
struct PolicyCanvasLabelPositionResolutionTests {
  private let blocker = CGRect(x: 1000, y: 1000, width: 168, height: 96)
  private let frames: [String: CGRect] = [
    "os": CGRect(x: 2000, y: 2000, width: 168, height: 96),
    "ot": CGRect(x: 2400, y: 2000, width: 168, height: 96),
    "blocker": CGRect(x: 1000, y: 1000, width: 168, height: 96),
  ]

  private func ownerEdge() -> PolicyCanvasEdge {
    PolicyCanvasEdge(
      id: "owner",
      source: PolicyCanvasPortEndpoint(nodeID: "os", portID: "out", kind: .output),
      target: PolicyCanvasPortEndpoint(nodeID: "ot", portID: "in", kind: .input),
      label: "parallel wait"
    )
  }

  private func report(
    labelPositions: [String: CGPoint]
  ) -> PolicyCanvasGraphQualityReport {
    policyCanvasMeasureGraphQuality(
      nodeFramesByID: frames,
      groupTitleFrames: [],
      edges: [ownerEdge()],
      // Route midpoint sits at (200, 300), nowhere near the blocker body.
      routes: [
        "owner": PolicyCanvasEdgeRoute(
          points: [CGPoint(x: 0, y: 300), CGPoint(x: 400, y: 300)],
          labelPosition: CGPoint(x: 200, y: 300)
        )
      ],
      labelPositions: labelPositions
    )
  }

  @Test func boxFollowsTheResolvedLabelPositionNotTheRouteMidpoint() {
    // The placement pass parked the label over the blocker body. The measure has
    // to box it there, so the on-body defect fires and the box centers on the
    // blocker - not at the empty route midpoint.
    let center = CGPoint(x: blocker.midX, y: blocker.midY)
    let result = report(labelPositions: ["owner": center])
    let onBody = try! #require(result.labels.first { $0.kind == .onBody })
    #expect(onBody.edgeID == "owner")
    #expect(onBody.otherID == "blocker")
    #expect(abs(onBody.frame.midX - center.x) < 1)
    #expect(abs(onBody.frame.midY - center.y) < 1)
  }

  @Test func absentOverrideFallsBackToRouteMidpoint() {
    // With no resolved position the label stays at its route midpoint, clear of
    // the blocker, so nothing fires - the fallback path the renderer also uses.
    let result = report(labelPositions: [:])
    #expect(result.labels.isEmpty)
  }
}
