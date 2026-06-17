import CoreGraphics
import Testing

@testable import HarnessMonitorPolicyCanvasAlgorithms

/// Crossed-ports detection: two wires landing on one node side in an order that
/// is inverted relative to where they come from must cross between the node and
/// their far ends. The measure flags that swap; a fan whose attach order matches
/// its source order stays clean.
struct PolicyCanvasCrossedPortsTests {
  private let target = CGRect(x: 400, y: 0, width: 168, height: 96)

  private func edge(_ id: String) -> PolicyCanvasEdge {
    PolicyCanvasEdge(
      id: id,
      source: PolicyCanvasPortEndpoint(nodeID: "s-\(id)", portID: "out", kind: .output),
      target: PolicyCanvasPortEndpoint(nodeID: "t", portID: "in", kind: .input),
      label: ""
    )
  }

  private func route(far: CGFloat, attach: CGFloat) -> PolicyCanvasEdgeRoute {
    // Far endpoint to the left at `far`, attaching to the target leading side at `attach`.
    PolicyCanvasEdgeRoute(points: [CGPoint(x: 0, y: far), CGPoint(x: 400, y: attach)], labelPosition: .zero)
  }

  private func report(routes: [String: PolicyCanvasEdgeRoute]) -> PolicyCanvasGraphQualityReport {
    policyCanvasMeasureGraphQuality(
      nodeFramesByID: ["t": target],
      groupTitleFrames: [],
      edges: routes.keys.sorted().map(edge),
      routes: routes
    )
  }

  @Test func invertedPortOrderIsFlagged() {
    // e1 attaches high (y=30) but comes from low (y=700); e2 attaches low (y=70)
    // but comes from high (y=10) - the wires cross.
    let result = report(routes: [
      "e1": route(far: 700, attach: 30),
      "e2": route(far: 10, attach: 70),
    ])
    #expect(result.count(for: .crossedPorts) == 1)
    let violation = try! #require(result.crossedPorts.first)
    #expect(violation.nodeID == "t")
    #expect(violation.side == .leading)
    #expect(Set([violation.edgeA, violation.edgeB]) == Set(["e1", "e2"]))
  }

  @Test func matchingPortOrderIsClean() {
    // e1 attaches high and comes from high; e2 attaches low and comes from low.
    let result = report(routes: [
      "e1": route(far: 10, attach: 30),
      "e2": route(far: 700, attach: 70),
    ])
    #expect(result.count(for: .crossedPorts) == 0)
  }

  @Test func singleEdgeNeverCrosses() {
    #expect(report(routes: ["e1": route(far: 10, attach: 48)]).count(for: .crossedPorts) == 0)
  }

  @Test func nonAdjacentInversionsAreAllCounted() {
    // Three ports: top->100, middle->200, bottom->50. The bottom port crosses
    // both the others (it is fed from above both), so two crossings - one of
    // them non-adjacent. All pairs are compared, not just neighbors.
    let result = report(routes: [
      "e1": route(far: 100, attach: 30),
      "e2": route(far: 200, attach: 60),
      "e3": route(far: 50, attach: 90),
    ])
    #expect(result.count(for: .crossedPorts) == 2)
  }

  @Test func sameFarPositionIsNotACross() {
    // Two wires from the same approach coordinate cannot cross each other.
    let result = report(routes: [
      "e1": route(far: 50, attach: 30),
      "e2": route(far: 50, attach: 70),
    ])
    #expect(result.count(for: .crossedPorts) == 0)
  }

  @Test func fanInThroughSharedChannelFlagsOnlyRealCrossings() {
    // Four wires funnel into one node side through a shared vertical channel
    // (x=2828), mirroring extreme-galaxy's Human gate fan-in. A one-dimensional
    // order key (where each wire came from) misreads this: it invents a crossing
    // between `switch` and `gate` (whose routes run parallel and never meet) and
    // misses the real `risk x evidence` and `gate x evidence` crossings. Only the
    // pairs whose polylines actually intersect between the ports are flagged.
    let node = CGRect(x: 2864, y: 6412, width: 168, height: 105)
    func fan(source: CGFloat, channelTurn: CGFloat, channelEntry: CGFloat, attach: CGFloat)
      -> PolicyCanvasEdgeRoute
    {
      PolicyCanvasEdgeRoute(
        points: [
          CGPoint(x: channelTurn - 36, y: source), CGPoint(x: channelTurn, y: source),
          CGPoint(x: channelTurn, y: channelEntry), CGPoint(x: 2828, y: channelEntry),
          CGPoint(x: 2828, y: attach), CGPoint(x: 2864, y: attach),
        ],
        labelPosition: .zero
      )
    }
    let result = policyCanvasMeasureGraphQuality(
      nodeFramesByID: ["t": node],
      groupTitleFrames: [],
      edges: ["risk", "switch", "gate", "evidence"].map(edge),
      routes: [
        "risk": fan(source: 6131.9, channelTurn: 2748, channelEntry: 6335, attach: 6423.4),
        "switch": fan(source: 5985.4, channelTurn: 2088, channelEntry: 6255, attach: 6450.8),
        "gate": fan(source: 5697.8, channelTurn: 1768, channelEntry: 6285, attach: 6478.2),
        "evidence": fan(source: 6198.2, channelTurn: 2088, channelEntry: 6295, attach: 6505.6),
      ]
    )
    let pairs = Set(result.crossedPorts.map { Set([$0.edgeA, $0.edgeB]) })
    #expect(
      pairs == [
        ["risk", "switch"], ["risk", "gate"], ["risk", "evidence"], ["gate", "evidence"],
      ],
      "expected only the pairs that actually cross; got \(pairs)"
    )
  }

  @Test func detouringWireIsNotCounted() {
    // e1 would invert against e2 by far position, but its route dives below the
    // node (y 900) then climbs back up to the top port (y 30) - a perpendicular
    // backtrack. That crossing is a routing detour, not a wrong-port pick, so the
    // far-position test (which assumes a direct approach) must not flag it.
    let detour = PolicyCanvasEdgeRoute(
      points: [
        CGPoint(x: 0, y: 700), CGPoint(x: 40, y: 700), CGPoint(x: 40, y: 900),
        CGPoint(x: 200, y: 900), CGPoint(x: 200, y: 30), CGPoint(x: 400, y: 30),
      ],
      labelPosition: .zero
    )
    let result = report(routes: [
      "e1": detour,
      "e2": route(far: 10, attach: 70),
    ])
    #expect(result.count(for: .crossedPorts) == 0)
  }

  @Test func directInvertedPairStillCountsAlongsideADetour() {
    // A third, direct wire pair that genuinely swaps still counts even when an
    // unrelated detouring wire shares the side - the detour is skipped, the real
    // swap is kept.
    let detour = PolicyCanvasEdgeRoute(
      points: [
        CGPoint(x: 0, y: 700), CGPoint(x: 40, y: 700), CGPoint(x: 40, y: 900),
        CGPoint(x: 200, y: 900), CGPoint(x: 200, y: 48), CGPoint(x: 400, y: 48),
      ],
      labelPosition: .zero
    )
    let result = report(routes: [
      "detour": detour,
      "e1": route(far: 700, attach: 20),
      "e2": route(far: 10, attach: 76),
    ])
    #expect(result.count(for: .crossedPorts) == 1)
    let violation = try! #require(result.crossedPorts.first)
    #expect(Set([violation.edgeA, violation.edgeB]) == Set(["e1", "e2"]))
  }
}
