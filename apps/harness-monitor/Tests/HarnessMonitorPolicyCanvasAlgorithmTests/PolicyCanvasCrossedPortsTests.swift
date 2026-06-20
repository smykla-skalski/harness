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
    // Three wires funnel into one leading side through a shared vertical channel
    // (x=360). The bottom port (e3) overshoots highest into the channel (entry 10,
    // above both others) then drops to its dot, so its run swaps past BOTH the top
    // port (e1, non-adjacent - e2 sits between them) and the middle port (e2,
    // adjacent). e1 and e2 keep their order and never share an overlapping run.
    // Two crossings, one non-adjacent: every pair is compared, not just neighbours.
    func channelRoute(source: CGFloat, attach: CGFloat) -> PolicyCanvasEdgeRoute {
      PolicyCanvasEdgeRoute(
        points: [
          CGPoint(x: 340, y: source), CGPoint(x: 360, y: source),
          CGPoint(x: 360, y: attach), CGPoint(x: 400, y: attach),
        ],
        labelPosition: .zero
      )
    }
    let result = policyCanvasMeasureGraphQuality(
      nodeFramesByID: ["t": target],
      groupTitleFrames: [],
      edges: ["e1", "e2", "e3"].map(edge),
      routes: [
        "e1": channelRoute(source: 55, attach: 30),
        "e2": channelRoute(source: 85, attach: 60),
        "e3": channelRoute(source: 10, attach: 90),
      ]
    )
    #expect(result.count(for: .crossedPorts) == 2)
    #expect(Set(result.crossedPorts.map { Set([$0.edgeA, $0.edgeB]) }) == [["e1", "e3"], ["e2", "e3"]])
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
    // (x=2828), mirroring extreme-galaxy's Human gate fan-in. `risk` attaches
    // highest yet overshoots lowest into the channel (entry 6335, below the other
    // three entries), so its run swaps past all of them. `switch`, `gate`, and
    // `evidence` keep their channel order and stay parallel, so none of those pairs
    // cross. Only the pairs that actually swap in the shared channel are flagged -
    // a one-dimensional order key would invent switch x gate and misread which wire
    // really reorders.
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
        ["risk", "switch"], ["risk", "gate"], ["risk", "evidence"],
      ],
      "expected only the pairs that actually swap in the channel; got \(pairs)"
    )
    // risk (6423.4) and switch (6450.8) are adjacent on the leading side - the
    // X sits at their midpoint, on the port column between the two dots.
    let adjacent = try! #require(
      result.crossedPorts.first { Set([$0.edgeA, $0.edgeB]) == ["risk", "switch"] })
    #expect(adjacent.markPoint == CGPoint(x: 2864, y: (6423.4 + 6450.8) / 2))
    // risk (6423.4) and evidence (6505.6) have switch and gate between them, so the
    // midpoint would land on a dot - the X is pushed one port diameter off the
    // leading side (to the left, the wire margin), never onto the node body.
    let spanning = try! #require(
      result.crossedPorts.first { Set([$0.edgeA, $0.edgeB]) == ["risk", "evidence"] })
    #expect(spanning.markPoint == CGPoint(x: 2864 - PolicyCanvasLayout.portDiameter, y: (6423.4 + 6505.6) / 2))
  }

  @Test func wiresSwappingInsideASharedChannelAreFlagged() {
    // Two inbound wires funnel down the SAME vertical channel (x=360) and swap to
    // their ports: `gate` comes from below, overshoots up the channel past the
    // ports, then drops to the LOWER port (y=230); `event` comes from below and
    // rises to the UPPER port (y=202). Their channel runs are collinear, so they
    // never form a proper interior intersection (the proper-crossing test misses
    // it), and `gate`'s overshoot reverses its y so the monotonic guard would drop
    // it. But sharing one channel and attaching in swapped order is a real port
    // cross - mirrors extreme-galaxy's Handoff fan-in. Contrast m13, where the
    // wires use separate channel lanes and so must not be flagged this way.
    let node = CGRect(x: 400, y: 180, width: 168, height: 105)
    let gate = PolicyCanvasEdgeRoute(
      points: [
        CGPoint(x: 100, y: 400), CGPoint(x: 140, y: 400), CGPoint(x: 140, y: 160),
        CGPoint(x: 360, y: 160), CGPoint(x: 360, y: 230), CGPoint(x: 400, y: 230),
      ],
      labelPosition: .zero
    )
    let event = PolicyCanvasEdgeRoute(
      points: [
        CGPoint(x: 300, y: 236), CGPoint(x: 360, y: 236), CGPoint(x: 360, y: 202),
        CGPoint(x: 400, y: 202),
      ],
      labelPosition: .zero
    )
    let result = policyCanvasMeasureGraphQuality(
      nodeFramesByID: ["t": node],
      groupTitleFrames: [],
      edges: ["gate", "event"].map(edge),
      routes: ["gate": gate, "event": event]
    )
    #expect(result.count(for: .crossedPorts) == 1)
    let violation = try! #require(result.crossedPorts.first)
    #expect(Set([violation.edgeA, violation.edgeB]) == Set(["gate", "event"]))
    #expect(violation.side == .leading)
  }

  @Test func wiresStackedInOneChannelWithoutSwappingStayClean() {
    // Both wires run down the same channel (x=360) but keep their order: `high`
    // attaches to the upper port and comes from higher up, `low` attaches lower
    // and comes from lower down. Same channel, no swap - not a cross.
    let node = CGRect(x: 400, y: 180, width: 168, height: 105)
    let high = PolicyCanvasEdgeRoute(
      points: [CGPoint(x: 300, y: 120), CGPoint(x: 360, y: 120), CGPoint(x: 360, y: 202), CGPoint(x: 400, y: 202)],
      labelPosition: .zero
    )
    let low = PolicyCanvasEdgeRoute(
      points: [CGPoint(x: 300, y: 320), CGPoint(x: 360, y: 320), CGPoint(x: 360, y: 230), CGPoint(x: 400, y: 230)],
      labelPosition: .zero
    )
    let result = policyCanvasMeasureGraphQuality(
      nodeFramesByID: ["t": node],
      groupTitleFrames: [],
      edges: ["high", "low"].map(edge),
      routes: ["high": high, "low": low]
    )
    #expect(result.count(for: .crossedPorts) == 0)
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
