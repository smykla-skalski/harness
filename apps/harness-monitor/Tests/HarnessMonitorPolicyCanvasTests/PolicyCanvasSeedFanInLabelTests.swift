import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

/// Failure fan-in coverage on the *seeded* policy graph after an engine
/// Reformat - the geometry the live Dashboard>Policies canvas actually renders.
///
/// The earlier `PolicyCanvasFailureFanInLabelTests` exercise the preview
/// pipeline document, whose initial grid coordinates arrange merge-deny one row
/// higher and leave the fan-in clean. The daemon seed (`seed.rs`) arranges from
/// its own tidy coordinates, drops merge-deny into the third terminal row, and
/// routes the blue `action -> default-allow` through-bus right over merge-deny's
/// top - 3pt from the lowest red fail run. That graze both reads as one
/// colliding line and blocks the fourth fail label out of its staircase, so it
/// lands crammed against the turn. These tests reproduce that exact layout.
@Suite("Policy canvas seeded failure fan-in placement")
@MainActor
struct PolicyCanvasSeedFanInLabelTests {
  // Issue 1: no through-flow bus may run near-parallel to a red fail run within
  // edge spacing. On the seeded layout the offender is edge:default, which rises
  // to clear merge-deny's top right alongside the lowest fail run.
  @Test("through-flow buses stay clear of the seeded fail fan")
  func throughFlowBusesStayClearOfTheFailFan() {
    let scene = seedReflowedScene()
    let minSeparation = PolicyCanvasLayout.defaultEdgeLineSpacing
    let meaningfulOverlap = PolicyCanvasLayout.gridSize * 3
    let throughFlowIDs = scene.viewModel.edges
      .filter { !scene.failEdgeIDs.contains($0.id) }
      .map(\.id)
    var violations: [String] = []
    for redID in scene.failEdgeIDs {
      guard let red = scene.routes[redID] else { continue }
      for blueID in throughFlowIDs {
        guard let blue = scene.routes[blueID] else { continue }
        for overlap in parallelProximities(red, blue)
        where overlap.length >= meaningfulOverlap && overlap.gap < minSeparation {
          let coordinate = Int(overlap.coordinate.rounded())
          let gap = Int(overlap.gap.rounded())
          let length = Int(overlap.length.rounded())
          violations.append(
            "\(redID)~\(blueID) \(overlap.axis)@\(coordinate) gap=\(gap) len=\(length)"
          )
        }
      }
    }
    #expect(violations.isEmpty, "near-parallel red/blue buses: \(violations)")
  }

  // Issue 2: every fail label sits on a horizontal run, never a vertical drop.
  @Test("seeded fail labels sit on horizontal runs")
  func failLabelsSitOnHorizontalRuns() {
    let scene = seedReflowedScene()
    for id in scene.failEdgeIDs {
      guard let route = scene.routes[id], let center = scene.labels[id] else {
        Issue.record("missing route/label for \(id)")
        continue
      }
      #expect(
        !labelOnVerticalSegment(center: center, route: route),
        "\(id) label sits on a vertical drop")
    }
  }

  // New issue + issue 2: a fail label keeps clearance from the turn it sits next
  // to, so it never spills onto the vertical leg it just turned off.
  @Test("seeded fail labels keep clearance after the turn")
  func failLabelsKeepClearanceAfterTheTurn() {
    let scene = seedReflowedScene()
    let size = PolicyCanvasEdgeLabelMetrics(fontScale: 1).size(for: "evidence failure")
    let minClearance = PolicyCanvasLayout.gridSize
    for id in scene.failEdgeIDs {
      guard let route = scene.routes[id], let center = scene.labels[id] else { continue }
      let clearance = horizontalCornerClearance(center: center, size: size, route: route)
      let actual = Int(clearance.rounded())
      let wanted = Int(minClearance.rounded())
      #expect(
        clearance >= minClearance,
        "\(id) label clears its turn by only \(actual)pt (want >= \(wanted))"
      )
    }
  }

  // Issue 4: the four fan-in labels step down their runs in even notches and
  // never overlap - no member orphaned far from the staircase.
  @Test("seeded fail labels step down their runs evenly")
  func failLabelsStepDownTheirRunsEvenly() {
    let scene = seedReflowedScene()
    let size = PolicyCanvasEdgeLabelMetrics(fontScale: 1).size(for: "evidence failure")
    let placed = scene.failEdgeIDs.compactMap { id in scene.labels[id].map { (id: id, center: $0) }
    }
    .sorted { $0.center.y < $1.center.y }
    #expect(placed.count == scene.failEdgeIDs.count)
    for left in 0..<placed.count {
      for right in (left + 1)..<placed.count {
        let leftFrame = labelFrame(center: placed[left].center, size: size)
        let rightFrame = labelFrame(center: placed[right].center, size: size)
        #expect(
          !leftFrame.intersects(rightFrame),
          "\(placed[left].id) and \(placed[right].id) labels overlap")
      }
    }
    let xs = placed.map(\.center.x)
    let steps = zip(xs, xs.dropFirst()).map { abs($0 - $1) }
    let evenLimit = PolicyCanvasLayout.gridSize * 8
    for (index, step) in steps.enumerated() {
      let actual = Int(step.rounded())
      let limit = Int(evenLimit.rounded())
      #expect(
        step <= evenLimit,
        "fan-in label step \(index) is \(actual)pt (want <= \(limit)) - label orphaned"
      )
    }
  }

  // MARK: - Scene

  struct Scene {
    let viewModel: PolicyCanvasViewModel
    let routes: [String: PolicyCanvasEdgeRoute]
    let labels: [String: CGPoint]
    let failEdgeIDs: [String]
  }

  func seedReflowedScene() -> Scene {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: seededDefaultPolicyDocument(revision: 71), simulation: nil, audit: nil)
    // The seeded coordinates are tidy, so loading them stays manual. Nudge one
    // terminal into overlap to release the tidy guard, then Reformat: the engine
    // arranges from the seed geometry into the exact live layout - merge-deny in
    // the third terminal row with the through-bus crossing its top.
    if let index = viewModel.nodes.firstIndex(where: { $0.id == "supervisor:auto-merge" }) {
      viewModel.nodes[index].position = CGPoint(x: 80, y: 124)
    }
    viewModel.reflowLayout()

    let edges = viewModel.edges
    let failEdgeIDs = edges.filter { $0.target.nodeID == "supervisor:merge-deny" }.map(\.id)
    let routes = policyCanvasDisplayedRoutes(
      viewModel: viewModel,
      edges: edges,
      portAnchors: viewModel.portAnchors(for: edges),
      router: PolicyCanvasVisibilityRouter()
    )
    let metrics = PolicyCanvasEdgeLabelMetrics(fontScale: 1)
    let placement = edges.compactMap { edge -> PolicyCanvasLabelPlacementRoute? in
      guard let route = routes[edge.id] else { return nil }
      // The seed fixture leaves fan-in labels empty; the live daemon stamps the
      // shared "evidence failure" text on every fail edge, which is what stacks
      // them into one fan-in family. Mirror that here.
      let text = failEdgeIDs.contains(edge.id) ? "evidence failure" : edge.label
      guard !text.isEmpty else { return nil }
      return PolicyCanvasLabelPlacementRoute(
        id: edge.id, label: text, route: route, size: metrics.size(for: text))
    }
    let nodeFrames =
      viewModel.nodes.map { CGRect(origin: $0.position, size: PolicyCanvasLayout.nodeSize) }
      + policyCanvasGroupTitleFrames(viewModel.groups)
    let labels = policyCanvasResolvedLabelPositions(
      routes: placement,
      nodeFrames: nodeFrames,
      routeFrames: policyCanvasRouteFrames(placement))
    return Scene(viewModel: viewModel, routes: routes, labels: labels, failEdgeIDs: failEdgeIDs)
  }

  // MARK: - Geometry helpers

  struct ParallelProximity {
    let axis: String
    let coordinate: CGFloat
    let gap: CGFloat
    let length: CGFloat
  }

  func parallelProximities(
    _ left: PolicyCanvasEdgeRoute, _ right: PolicyCanvasEdgeRoute
  ) -> [ParallelProximity] {
    var out: [ParallelProximity] = []
    for (a0, a1) in zip(left.points, left.points.dropFirst()) {
      for (b0, b1) in zip(right.points, right.points.dropFirst()) {
        if abs(a0.y - a1.y) < 0.5, abs(b0.y - b1.y) < 0.5 {
          let low = max(min(a0.x, a1.x), min(b0.x, b1.x))
          let high = min(max(a0.x, a1.x), max(b0.x, b1.x))
          if high - low > 0 {
            out.append(
              .init(axis: "H", coordinate: a0.y, gap: abs(a0.y - b0.y), length: high - low))
          }
        }
        if abs(a0.x - a1.x) < 0.5, abs(b0.x - b1.x) < 0.5 {
          let low = max(min(a0.y, a1.y), min(b0.y, b1.y))
          let high = min(max(a0.y, a1.y), max(b0.y, b1.y))
          if high - low > 0 {
            out.append(
              .init(axis: "V", coordinate: a0.x, gap: abs(a0.x - b0.x), length: high - low))
          }
        }
      }
    }
    return out
  }

  func labelOnVerticalSegment(center: CGPoint, route: PolicyCanvasEdgeRoute) -> Bool {
    for (p0, p1) in zip(route.points, route.points.dropFirst()) {
      guard abs(p0.x - p1.x) < 0.5, abs(p0.y - p1.y) > 0.5 else { continue }
      if abs(center.x - p0.x) < 8, (min(p0.y, p1.y) - 8)...(max(p0.y, p1.y) + 8) ~= center.y {
        return true
      }
    }
    return false
  }

  func horizontalCornerClearance(
    center: CGPoint, size: CGSize, route: PolicyCanvasEdgeRoute
  ) -> CGFloat {
    var best = -CGFloat.greatestFiniteMagnitude
    for (p0, p1) in zip(route.points, route.points.dropFirst()) {
      guard abs(p0.y - p1.y) < 0.5, abs(p0.x - p1.x) > 0.5 else { continue }
      guard abs(center.y - p0.y) < size.height / 2 + 1 else { continue }
      let minX = min(p0.x, p1.x)
      let maxX = max(p0.x, p1.x)
      guard (minX - 1)...(maxX + 1) ~= center.x else { continue }
      let leftClear = (center.x - size.width / 2) - minX
      let rightClear = maxX - (center.x + size.width / 2)
      best = max(best, min(leftClear, rightClear))
    }
    return best == -CGFloat.greatestFiniteMagnitude ? 0 : best
  }

  func labelFrame(center: CGPoint, size: CGSize) -> CGRect {
    CGRect(
      x: center.x - size.width / 2, y: center.y - size.height / 2,
      width: size.width, height: size.height)
  }
}
