import CoreGraphics
import Foundation
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

/// Acceptance gate for the crossing-aware route post-process (Path A). The
/// orthogonal nudge clears interior overlaps but trades them for X-crossings it
/// introduces by spreading a riser into a foreign edge's stub span. This pass must
/// clear the same overlaps while adding *zero* crossings over the no-nudge
/// (`collinearRouteCompression`) baseline - strictly better than the nudge, which
/// adds three on `branching`/`multi-group`. The proven nudge-introduced pairs are
/// `coll-allow`x`coll-human` (branching) and `pre-intake`x`pre-deny` /
/// `rv-else`x`dp-fail` (multi-group); none may appear in the added set.
@Suite("Policy canvas Claude crossing-aware route processing", .serialized)
@MainActor
struct PolicyCanvasClaudeCrossingAwareRouteTests {
  /// Collinear overlap of an interior segment between two edges, longer than this,
  /// reads as two wires stacked on one rail. Matches the fan-in channel gate.
  private static let overlapThreshold: CGFloat = 8

  /// The hard, monotone-safe guarantee across every sample: the pass never adds a
  /// crossing and never adds an overlap over the no-nudge baseline. In a saturated
  /// corridor it may decline to clear an overlap (no spread direction is
  /// crossing-free), but it can never regress one into a crossing or stack a new
  /// pair - so it is always safe to prefer over the raw routing.
  @Test("never adds a crossing or an overlap on any sample")
  func neverRegressesCrossingsOrOverlaps() async throws {
    let baseline = PolicyCanvasAlgorithmSelection.referenceRouting.replacing(
      stage: .routePostProcessing,
      with: PolicyCanvasAlgorithmDefaults.collinearRouteCompression
    )
    let claude = PolicyCanvasAlgorithmSelection.referenceRouting.replacing(
      stage: .routePostProcessing,
      with: PolicyCanvasAlgorithmDefaults.claudeCrossingAwareRouteProcessing
    )
    var totals = ""
    var regressions: [String] = []
    for sampleID in PolicyCanvasLabSamples.all.map(\.id) {
      let base = try await routedScene(sampleID: sampleID, selection: baseline)
      let after = try await routedScene(sampleID: sampleID, selection: claude)
      let baseOverlaps = interiorOverlapPairs(routes: base.routes, edges: base.edges)
      let baseCrossings = Set(crossingPairs(routes: base.routes, edges: base.edges))
      let afterOverlaps = interiorOverlapPairs(routes: after.routes, edges: after.edges)
      let afterCrossings = Set(crossingPairs(routes: after.routes, edges: after.edges))
      let addedCrossings = afterCrossings.subtracting(baseCrossings).sorted()
      totals +=
        "\(sampleID): overlaps \(baseOverlaps.count)->\(afterOverlaps.count)"
        + "  addedCrossings \(addedCrossings.count)\n"
      if !addedCrossings.isEmpty {
        regressions.append("\(sampleID): added crossings \(addedCrossings)")
      }
      if afterOverlaps.count > baseOverlaps.count {
        regressions.append(
          "\(sampleID): added overlaps \(baseOverlaps.count)->\(afterOverlaps.count)"
        )
      }
    }
    #expect(
      regressions.isEmpty,
      "the crossing-aware pass regressed a sample\n\(regressions.joined(separator: "\n"))\nTOTALS\n\(totals)"
    )
  }

  /// Where the nudge can only de-overlap by adding crossings (the crowded
  /// branching and multi-group corridors), the crossing-aware pass clears overlaps
  /// the baseline had while adding none. This is the concrete improvement over
  /// both the baseline (which leaves the overlaps stacked) and the nudge (which
  /// trades them for X-crossings).
  @Test("clears clearable overlaps with no crossing where the nudge needs one")
  func clearsClearableOverlapsWhereTheNudgeAddsCrossings() async throws {
    let baseline = PolicyCanvasAlgorithmSelection.referenceRouting.replacing(
      stage: .routePostProcessing,
      with: PolicyCanvasAlgorithmDefaults.collinearRouteCompression
    )
    let nudged = PolicyCanvasAlgorithmSelection.referenceRouting.replacing(
      stage: .routePostProcessing,
      with: PolicyCanvasAlgorithmDefaults.orthogonalNudgedRouteProcessing
    )
    let claude = PolicyCanvasAlgorithmSelection.referenceRouting.replacing(
      stage: .routePostProcessing,
      with: PolicyCanvasAlgorithmDefaults.claudeCrossingAwareRouteProcessing
    )
    for sampleID in ["branching", "multi-group"] {
      let base = try await routedScene(sampleID: sampleID, selection: baseline)
      let nudge = try await routedScene(sampleID: sampleID, selection: nudged)
      let after = try await routedScene(sampleID: sampleID, selection: claude)
      let baseOverlaps = interiorOverlapPairs(routes: base.routes, edges: base.edges)
      let afterOverlaps = interiorOverlapPairs(routes: after.routes, edges: after.edges)
      let baseCrossings = Set(crossingPairs(routes: base.routes, edges: base.edges))
      let nudgeAdded = Set(crossingPairs(routes: nudge.routes, edges: nudge.edges))
        .subtracting(baseCrossings)
      let afterAdded = Set(crossingPairs(routes: after.routes, edges: after.edges))
        .subtracting(baseCrossings)
      #expect(
        afterOverlaps.count < baseOverlaps.count,
        "\(sampleID): expected to clear an overlap, got \(baseOverlaps.count)->\(afterOverlaps.count)"
      )
      #expect(
        afterAdded.isEmpty,
        "\(sampleID): the crossing-aware pass added crossings \(afterAdded.sorted())"
      )
      #expect(
        !nudgeAdded.isEmpty,
        "\(sampleID): expected the nudge to add a crossing here so the comparison is meaningful"
      )
    }
  }

  /// The greedy per-channel choice reads channels from a dictionary-grouped
  /// source, so it must sort everything it touches to stay order-independent.
  /// Routing the same laid-out graph with the edges fed forward and reversed must
  /// produce byte-identical routes under the preset.
  @Test("routing under the preset is independent of edge input order")
  func deterministicAcrossEdgeOrder() async throws {
    let claude = PolicyCanvasAlgorithmSelection.referenceRouting.replacing(
      stage: .routePostProcessing,
      with: PolicyCanvasAlgorithmDefaults.claudeCrossingAwareRouteProcessing
    )
    let sample = try #require(PolicyCanvasLabSamples.sample(id: "multi-group"))
    let document =
      PolicyCanvasLabSnapshotSupport.document(sample.document, includesGroups: false)
      ?? sample.document
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: document, simulation: nil, audit: nil)
    viewModel.reflowLayout(preserveManualAnchors: false, force: true)
    func routed(_ edges: [PolicyCanvasEdge]) async -> [String: PolicyCanvasEdgeRoute] {
      let input = PolicyCanvasRouteWorkerInput(
        nodes: viewModel.nodes,
        groups: viewModel.groups,
        edges: edges,
        fontScale: 1,
        routingHints: viewModel.routingHints,
        algorithmSelection: claude
      )
      return await PolicyCanvasRouteWorker().compute(input: input).routes
    }
    let forward = await routed(viewModel.edges)
    let reversed = await routed(Array(viewModel.edges.reversed()))
    #expect(Set(forward.keys) == Set(reversed.keys))
    for id in forward.keys.sorted() {
      #expect(
        forward[id]?.points == reversed[id]?.points,
        "\(id): route differs across edge input order"
      )
    }
  }

  // MARK: - Scene

  private struct Scene {
    let edges: [PolicyCanvasEdge]
    let routes: [String: PolicyCanvasEdgeRoute]
  }

  private func routedScene(
    sampleID: String,
    selection: PolicyCanvasAlgorithmSelection
  ) async throws -> Scene {
    let sample = try #require(PolicyCanvasLabSamples.sample(id: sampleID))
    // Strip groups so layout/routing/post-processing work on plain nodes + edges -
    // the same group-free graph the fan-in channel gate is tuned against.
    let document =
      PolicyCanvasLabSnapshotSupport.document(sample.document, includesGroups: false)
      ?? sample.document
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: document, simulation: nil, audit: nil)
    viewModel.reflowLayout(preserveManualAnchors: false, force: true)
    let edges = viewModel.edges
    let input = PolicyCanvasRouteWorkerInput(
      nodes: viewModel.nodes,
      groups: viewModel.groups,
      edges: edges,
      fontScale: 1,
      routingHints: viewModel.routingHints,
      algorithmSelection: selection
    )
    let output = await PolicyCanvasRouteWorker().compute(input: input)
    return Scene(edges: edges, routes: output.routes)
  }

  // MARK: - Metrics (mirrors PolicyCanvasFanInChannelTests; helpers there are private)

  private func interiorOverlapPairs(
    routes: [String: PolicyCanvasEdgeRoute],
    edges: [PolicyCanvasEdge]
  ) -> [String] {
    let interior = edges.compactMap { edge -> (id: String, segments: [PolicyCanvasRouteSegment])? in
      guard let route = routes[edge.id] else {
        return nil
      }
      return (edge.id, Array(policyCanvasRouteSegments(route).dropFirst().dropLast()))
    }
    var pairs: [String] = []
    for left in interior.indices {
      for right in interior.index(after: left)..<interior.endIndex {
        let overlap = maximumOverlap(interior[left].segments, interior[right].segments)
        if overlap > Self.overlapThreshold {
          pairs.append("\(interior[left].id) ~ \(interior[right].id) (\(Int(overlap)))")
        }
      }
    }
    return pairs
  }

  private func maximumOverlap(
    _ left: [PolicyCanvasRouteSegment],
    _ right: [PolicyCanvasRouteSegment]
  ) -> CGFloat {
    var best: CGFloat = 0
    for leftSegment in left {
      for rightSegment in right where leftSegment.sharesAxisLane(with: rightSegment) {
        best = max(best, leftSegment.overlap(with: rightSegment))
      }
    }
    return best
  }

  private func crossingPairs(
    routes: [String: PolicyCanvasEdgeRoute],
    edges: [PolicyCanvasEdge]
  ) -> [String] {
    let realized = edges.compactMap { edge in
      routes[edge.id].map { (id: edge.id, route: $0) }
    }
    var crossings: [String] = []
    for left in realized.indices {
      for right in realized.index(after: left)..<realized.endIndex
      where routesProperlyCross(realized[left].route, realized[right].route) {
        crossings.append("\(realized[left].id) x \(realized[right].id)")
      }
    }
    return crossings
  }

  private func routesProperlyCross(
    _ left: PolicyCanvasEdgeRoute,
    _ right: PolicyCanvasEdgeRoute
  ) -> Bool {
    for (a0, a1) in zip(left.points, left.points.dropFirst()) {
      for (b0, b1) in zip(right.points, right.points.dropFirst())
      where segmentsProperlyCross(a0, a1, b0, b1) {
        return true
      }
    }
    return false
  }

  private func segmentsProperlyCross(
    _ a0: CGPoint,
    _ a1: CGPoint,
    _ b0: CGPoint,
    _ b1: CGPoint
  ) -> Bool {
    let tolerance: CGFloat = 0.5
    let aHorizontal = abs(a0.y - a1.y) < tolerance
    let aVertical = abs(a0.x - a1.x) < tolerance
    let bHorizontal = abs(b0.y - b1.y) < tolerance
    let bVertical = abs(b0.x - b1.x) < tolerance
    if aHorizontal, bVertical {
      let crossX = b0.x
      let crossY = a0.y
      return crossX > min(a0.x, a1.x) + tolerance
        && crossX < max(a0.x, a1.x) - tolerance
        && crossY > min(b0.y, b1.y) + tolerance
        && crossY < max(b0.y, b1.y) - tolerance
    }
    if aVertical, bHorizontal {
      return segmentsProperlyCross(b0, b1, a0, a1)
    }
    return false
  }
}
