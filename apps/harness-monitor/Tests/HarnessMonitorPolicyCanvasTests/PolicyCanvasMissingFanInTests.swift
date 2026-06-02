import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas

/// The live "Default" policy fans six distinct check sources (five `switch`
/// merge checks plus the risk classifier) into the single `in` port of
/// `human:missing-merge-evidence`, every edge labelled "missing". They are a
/// genuine multi-source fan-in - different sources, so the merged-wire fold
/// (same source + target) never applies. On the shared-lane corridor they reach
/// one horizontal bus in a different order than their top markers and cross just
/// above the gate. These tests pin that the six rails approach without crossing.
@Suite("Policy canvas missing-evidence fan-in")
@MainActor
struct PolicyCanvasMissingFanInTests {
  private let gateID = "human:missing-merge-evidence"

  @Test("the six missing rails approach the human gate without crossing")
  func missingRailsDoNotCross() {
    let scene = fanInScene()
    let routes = scene.missingEdgeIDs.compactMap { id in scene.routes[id].map { (id, $0) } }
    #expect(routes.count == scene.missingEdgeIDs.count, "every missing edge routed")

    var crossings: [String] = []
    for left in 0..<routes.count {
      for right in (left + 1)..<routes.count where routesProperlyCross(routes[left].1, routes[right].1) {
        crossings.append("\(routes[left].0) x \(routes[right].0)")
      }
    }
    #expect(crossings.isEmpty, "missing rails cross: \(crossings)")
  }

  @Test("each missing rail descends in its own corridor lane")
  func missingRailsUseDistinctLanes() {
    let scene = fanInScene()
    // Every rail ends with a short vertical drop into its own port marker; those
    // drop columns must be distinct, otherwise two rails share a column and the
    // fan reads as a single congested stub.
    let dropColumns = scene.missingEdgeIDs.compactMap { id -> CGFloat? in
      guard let route = scene.routes[id] else { return nil }
      return finalVerticalColumn(route)
    }
    #expect(dropColumns.count == scene.missingEdgeIDs.count, "every rail ends on a vertical drop")
    let distinct = Set(dropColumns.map { Int(($0 / 2).rounded()) })
    #expect(distinct.count == dropColumns.count, "rails share a drop column: \(dropColumns)")
  }

  @Test("missing rails neither overshoot above the gate nor pierce its body")
  func missingRailsStayClearOfTheGateBody() {
    let scene = fanInScene()
    guard let gate = scene.viewModel.node(gateID) else {
      Issue.record("gate node missing")
      return
    }
    let gateFrame = CGRect(origin: gate.position, size: PolicyCanvasLayout.nodeSize)
    let eps: CGFloat = 1
    var overshoots: [String] = []
    var pierces: [String] = []
    for id in scene.missingEdgeIDs {
      guard let route = scene.routes[id] else { continue }
      // The comb lifts the gate above its sources, so every rail enters from the
      // bottom. A point above the gate's top edge is the overshoot-and-hook-back.
      if route.points.contains(where: { $0.y < gateFrame.minY - eps }) {
        overshoots.append(id)
      }
      // Rails meet the port on the boundary; no segment may cross the node body.
      for (p0, p1) in zip(route.points, route.points.dropFirst())
      where axisSegmentEntersRect(p0, p1, gateFrame.insetBy(dx: eps, dy: eps)) {
        pierces.append(id)
        break
      }
    }
    #expect(overshoots.isEmpty, "rails overshoot above the gate: \(overshoots)")
    #expect(pierces.isEmpty, "rails pierce the gate body: \(pierces)")
  }

  @Test("each turn is followed by a segment long enough to read as a corner")
  func missingRailsKeepMinimumSegmentAfterEachTurn() {
    let scene = fanInScene()
    let minimum = PolicyCanvasLayout.gridSize
    var offenders: [String] = []
    for id in scene.missingEdgeIDs {
      guard let route = scene.routes[id] else { continue }
      let interior = route.points.dropFirst().dropLast()
      // Each interior vertex is a turn; the segment leaving it must be long enough
      // not to read as a stub-after-a-turn.
      for (index, _) in interior.enumerated() {
        let here = route.points[index + 1]
        let next = route.points[index + 2]
        if hypot(next.x - here.x, next.y - here.y) < minimum - 0.5 {
          offenders.append("\(id)@\(index)")
        }
      }
    }
    #expect(offenders.isEmpty, "segment after a turn is too short: \(offenders)")
  }

  // MARK: - Scene

  struct Scene {
    let viewModel: PolicyCanvasViewModel
    let routes: [String: PolicyCanvasEdgeRoute]
    let missingEdgeIDs: [String]
  }

  private func fanInScene() -> Scene {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: missingFanInDocument(revision: 4), simulation: nil, audit: nil)
    // Match the live lab, which force-arranges via `forcesAutoArrange`. Plain
    // `reflowLayout()` early-returns on the tidy fixture layout, so the comb
    // pass that lifts the shared collector above its sources never runs and the
    // test would exercise saved geometry instead of the live geometry.
    viewModel.reflowLayout(preserveManualAnchors: false, force: true)
    let edges = viewModel.edges
    let missingEdgeIDs = edges.filter { $0.target.nodeID == gateID }.map(\.id).sorted()
    let routes = policyCanvasDisplayedRoutes(
      viewModel: viewModel,
      edges: edges,
      portAnchors: viewModel.portAnchors(for: edges),
      router: PolicyCanvasVisibilityRouter()
    )
    return Scene(viewModel: viewModel, routes: routes, missingEdgeIDs: missingEdgeIDs)
  }

  // MARK: - Geometry

  private func routesProperlyCross(
    _ left: PolicyCanvasEdgeRoute, _ right: PolicyCanvasEdgeRoute
  ) -> Bool {
    for (a0, a1) in zip(left.points, left.points.dropFirst()) {
      for (b0, b1) in zip(right.points, right.points.dropFirst())
      where segmentsProperlyCross(a0, a1, b0, b1) {
        return true
      }
    }
    return false
  }

  /// True only when one axis-aligned segment is horizontal, the other vertical,
  /// and they meet at a point strictly interior to both - a real X-crossing, not
  /// a shared endpoint, T-junction, or collinear overlap at the convergence.
  private func segmentsProperlyCross(
    _ a0: CGPoint, _ a1: CGPoint, _ b0: CGPoint, _ b1: CGPoint
  ) -> Bool {
    let eps: CGFloat = 0.5
    let aHorizontal = abs(a0.y - a1.y) < eps
    let aVertical = abs(a0.x - a1.x) < eps
    let bHorizontal = abs(b0.y - b1.y) < eps
    let bVertical = abs(b0.x - b1.x) < eps
    if aHorizontal, bVertical {
      let crossX = b0.x
      let crossY = a0.y
      return crossX > min(a0.x, a1.x) + eps && crossX < max(a0.x, a1.x) - eps
        && crossY > min(b0.y, b1.y) + eps && crossY < max(b0.y, b1.y) - eps
    }
    if aVertical, bHorizontal {
      return segmentsProperlyCross(b0, b1, a0, a1)
    }
    return false
  }

  private func finalVerticalColumn(_ route: PolicyCanvasEdgeRoute) -> CGFloat? {
    for (p0, p1) in zip(route.points, route.points.dropFirst()).reversed()
    where abs(p0.x - p1.x) < 0.5 && abs(p0.y - p1.y) > 0.5 {
      return p0.x
    }
    return nil
  }

  /// True when an axis-aligned segment passes through the rect's interior rather
  /// than merely touching an edge - used to detect a rail crossing the gate body.
  private func axisSegmentEntersRect(_ p0: CGPoint, _ p1: CGPoint, _ rect: CGRect) -> Bool {
    guard rect.width > 0, rect.height > 0 else { return false }
    let eps: CGFloat = 0.5
    if abs(p0.y - p1.y) < eps {
      let y = p0.y
      guard y > rect.minY + eps, y < rect.maxY - eps else { return false }
      return max(p0.x, p1.x) > rect.minX + eps && min(p0.x, p1.x) < rect.maxX - eps
    }
    if abs(p0.x - p1.x) < eps {
      let x = p0.x
      guard x > rect.minX + eps, x < rect.maxX - eps else { return false }
      return max(p0.y, p1.y) > rect.minY + eps && min(p0.y, p1.y) < rect.maxY - eps
    }
    return false
  }
}

private func missingFanInDocument(revision: UInt64) -> TaskBoardPolicyPipelineDocument {
  let switches = [
    "switch:merge:checks-green",
    "switch:merge:branch-protection",
    "switch:merge:reviewer-approved",
    "switch:merge:requested-changes",
    "switch:merge:protected-path",
  ]
  var nodes: [TaskBoardPolicyPipelineNode] = switches.map { id in
    TaskBoardPolicyPipelineNode(
      id: id,
      title: id,
      kind: TaskBoardPolicyPipelineNodeKind(kind: "switch"),
      groupId: "merge",
      inputs: [TaskBoardPolicyPipelinePort(id: "in", title: "in")],
      outputs: [
        TaskBoardPolicyPipelinePort(id: "case_1", title: "missing"),
        TaskBoardPolicyPipelinePort(id: "case_2", title: "ok"),
      ]
    )
  }
  nodes.append(
    TaskBoardPolicyPipelineNode(
      id: "risk:merge",
      title: "risk:merge",
      kind: TaskBoardPolicyPipelineNodeKind(kind: "risk_classifier"),
      groupId: "merge",
      inputs: [TaskBoardPolicyPipelinePort(id: "in", title: "in")],
      outputs: [
        TaskBoardPolicyPipelinePort(id: "low_or_equal", title: "low"),
        TaskBoardPolicyPipelinePort(id: "high", title: "high"),
        TaskBoardPolicyPipelinePort(id: "missing", title: "missing"),
      ]
    )
  )
  nodes.append(
    TaskBoardPolicyPipelineNode(
      id: "human:missing-merge-evidence",
      title: "human:missing-merge-evidence",
      kind: TaskBoardPolicyPipelineNodeKind(kind: "human_gate"),
      groupId: "terminal",
      inputs: [TaskBoardPolicyPipelinePort(id: "in", title: "in")]
    )
  )

  var edges: [TaskBoardPolicyPipelineEdge] = switches.map { id in
    TaskBoardPolicyPipelineEdge(
      id: "edge:\(id):missing",
      fromNodeId: id,
      fromPort: "case_1",
      toNodeId: "human:missing-merge-evidence",
      toPort: "in",
      label: "missing"
    )
  }
  edges.append(
    TaskBoardPolicyPipelineEdge(
      id: "edge:risk-missing",
      fromNodeId: "risk:merge",
      fromPort: "missing",
      toNodeId: "human:missing-merge-evidence",
      toPort: "in",
      label: "missing"
    )
  )
  // Chain the checks left-to-right (each "ok" feeds the next, last into risk) so
  // the engine lays them on a single-rank spine like the live policy. Without the
  // chain the unconnected checks land on a multi-row grid no fan-in can serve.
  let chainTargets = Array(switches.dropFirst()) + ["risk:merge"]
  for (from, to) in zip(switches, chainTargets) {
    edges.append(
      TaskBoardPolicyPipelineEdge(
        id: "edge:\(from):ok",
        fromNodeId: from,
        fromPort: "case_2",
        toNodeId: to,
        toPort: "in",
        label: "ok"
      )
    )
  }

  let sources = switches + ["risk:merge"]
  let layout = TaskBoardPolicyPipelineLayout(
    nodes: sources.enumerated().map { index, id in
      TaskBoardPolicyPipelineNodeLayout(nodeId: id, x: 120 + index * 240, y: 120)
    } + [TaskBoardPolicyPipelineNodeLayout(nodeId: "human:missing-merge-evidence", x: 600, y: 460)]
  )

  return TaskBoardPolicyPipelineDocument(
    schemaVersion: 2,
    revision: revision,
    mode: .draft,
    nodes: nodes,
    edges: edges,
    groups: [
      TaskBoardPolicyPipelineGroup(id: "merge", title: "Merge checks", nodeIds: sources),
      TaskBoardPolicyPipelineGroup(
        id: "terminal", title: "Terminal", nodeIds: ["human:missing-merge-evidence"]),
    ],
    layout: layout,
    policyTraceIds: []
  )
}
