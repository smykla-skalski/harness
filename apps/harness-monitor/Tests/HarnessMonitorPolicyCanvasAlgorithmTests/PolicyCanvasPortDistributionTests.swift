import CoreGraphics
import Testing

@testable import HarnessMonitorPolicyCanvasAlgorithms

/// Port even-distribution detection: the dots on one node side should sit at the
/// canonical evenly-spread slots for their count (`PolicyCanvasLayout.portY`). A
/// dot pulled far off its slot - dots clustered at one end, or crammed toward the
/// center instead of spread - reads as a mis-placed port even when the pairwise
/// spacing alone would not explain it.
struct PolicyCanvasPortDistributionTests {
  private let target = CGRect(x: 400, y: 0, width: 168, height: 96)

  private func edge(_ id: String) -> PolicyCanvasEdge {
    PolicyCanvasEdge(
      id: id,
      source: PolicyCanvasPortEndpoint(nodeID: "s-\(id)", portID: "out", kind: .output),
      target: PolicyCanvasPortEndpoint(nodeID: "t", portID: "in", kind: .input),
      label: ""
    )
  }

  /// A wire landing on the target leading side at content y `attach`.
  private func route(attach: CGFloat) -> PolicyCanvasEdgeRoute {
    PolicyCanvasEdgeRoute(points: [CGPoint(x: 0, y: attach), CGPoint(x: 400, y: attach)], labelPosition: .zero)
  }

  private func report(attachments: [String: CGFloat]) -> PolicyCanvasGraphQualityReport {
    policyCanvasMeasureGraphQuality(
      nodeFramesByID: ["t": target],
      groupTitleFrames: [],
      edges: attachments.keys.sorted().map(edge),
      routes: attachments.reduce(into: [:]) { $0[$1.key] = route(attach: $1.value) }
    )
  }

  @Test func evenlyDistributedPortsAreClean() {
    // Three dots at exactly the canonical even slots for count 3 (21, 48, 75).
    let result = report(attachments: ["e1": 21, "e2": 48, "e3": 75])
    #expect(result.count(for: .portUneven) == 0)
  }

  @Test func clusteredPortsAreFlagged() {
    // Three dots crammed into the top of the side (11, 21, 36) instead of spread
    // across it - the Human-gate-14 case. Dots off their even slot are flagged.
    let result = report(attachments: ["e1": 11, "e2": 21, "e3": 36])
    #expect(result.count(for: .portUneven) >= 1)
    let uneven = try! #require(result.portSpacing.first { $0.kind == .uneven })
    #expect(uneven.nodeID == "t")
    #expect(uneven.side == .leading)
    // The ideal slot it should occupy is carried as `otherPoint`.
    #expect(uneven.otherPoint != nil)
  }

  @Test func unevenGapsAreFlagged() {
    // Two dots crammed near the top then one far down (11, 21, 75): the middle
    // pair crowds while the span yawns - not an even spread.
    let result = report(attachments: ["e1": 11, "e2": 21, "e3": 75])
    #expect(result.count(for: .portUneven) >= 1)
  }

  @Test func singleDotIsNeverUneven() {
    #expect(report(attachments: ["e1": 48]).count(for: .portUneven) == 0)
  }

  @Test func tallNodeWithEvenlySpreadPortsIsClean() {
    // A node sized by port demand is taller than the default node height. Its six
    // evenly-spread dots sit at portY(index, count: 6, nodeHeight: 159) =
    // 12, 39, 66, 93, 120, 147 - the Action-gate-14 trailing fan. The measure must
    // judge them against the node's ACTUAL height, not the default, or every
    // interior dot reads as mis-placed.
    let tall = CGRect(x: 400, y: 0, width: 168, height: 159)
    let attachments: [String: CGFloat] = [
      "e0": 12, "e1": 39, "e2": 66, "e3": 93, "e4": 120, "e5": 147,
    ]
    let result = policyCanvasMeasureGraphQuality(
      nodeFramesByID: ["t": tall],
      groupTitleFrames: [],
      edges: attachments.keys.sorted().map(edge),
      routes: attachments.reduce(into: [:]) { $0[$1.key] = route(attach: $1.value) }
    )
    #expect(result.count(for: .portUneven) == 0)
  }
}
