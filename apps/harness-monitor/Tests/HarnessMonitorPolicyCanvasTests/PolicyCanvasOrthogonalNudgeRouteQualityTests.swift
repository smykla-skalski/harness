import CoreGraphics
import Foundation
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

/// Acceptance gate for the crossing-aware orthogonal nudge - the production
/// route post-process default. A naive nudge clears interior overlaps but trades
/// them for X-crossings it introduces by spreading a riser into a foreign edge's
/// stub span. This pass must clear the same overlaps while adding *zero* crossings
/// over the no-nudge (`collinearRouteCompression`) baseline. The pairs a naive
/// nudge introduced are `coll-allow`x`coll-human` (branching) and
/// `pre-intake`x`pre-deny` / `rv-else`x`dp-fail` (multi-group); none may appear in
/// the added set.
@Suite("Policy canvas orthogonal nudge route quality", .serialized)
@MainActor
struct PolicyCanvasOrthogonalNudgeRouteQualityTests {
  /// Collinear overlap of an interior segment between two edges, longer than this,
  /// reads as two wires stacked on one rail. Matches the fan-in channel gate.
  private static let overlapThreshold: CGFloat = 8

  /// The hard, monotone-safe guarantee across the reference routing sample ladder:
  /// the pass never adds a crossing and never adds an overlap over the no-nudge
  /// baseline. In a saturated corridor it may decline to clear an overlap (no
  /// spread direction is crossing-free), but it can never regress one into a
  /// crossing or stack a new pair - so it is always safe to prefer over the raw
  /// routing.
  @Test("never adds a crossing or an overlap on reference samples")
  func neverRegressesCrossingsOrOverlaps() async throws {
    let baseline = Self.routeQualitySelection(
      routePostProcessing: PolicyCanvasAlgorithmDefaults.collinearRouteCompression
    )
    let nudged = Self.routeQualitySelection(
      routePostProcessing: PolicyCanvasAlgorithmDefaults.orthogonalNudgedRouteProcessing
    )
    var totals = ""
    var regressions: [String] = []
    for sampleID in PolicyCanvasReferenceAlgorithmSamples.ids {
      let base = try await routedScene(sampleID: sampleID, selection: baseline)
      let after = try await routedScene(sampleID: sampleID, selection: nudged)
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

  /// In the crowded branching corridor - where a naive nudge could only
  /// de-overlap by adding crossings - the crossing-aware pass clears the spacing
  /// conflicts the baseline left stacked while adding none.
  @Test("clearable corridors improve without adding a crossing")
  func clearableCorridorsImproveWithoutAddingCrossing() async throws {
    let baseline = Self.routeQualitySelection(
      routePostProcessing: PolicyCanvasAlgorithmDefaults.collinearRouteCompression
    )
    let nudged = Self.routeQualitySelection(
      routePostProcessing: PolicyCanvasAlgorithmDefaults.orthogonalNudgedRouteProcessing
    )
    let base = try await routedScene(sampleID: "branching", selection: baseline)
    let after = try await routedScene(sampleID: "branching", selection: nudged)
    let baseOverlaps = interiorOverlapPairs(routes: base.routes, edges: base.edges)
    let afterOverlaps = interiorOverlapPairs(routes: after.routes, edges: after.edges)
    let baseCrossings = Set(crossingPairs(routes: base.routes, edges: base.edges))
    let afterAdded = Set(crossingPairs(routes: after.routes, edges: after.edges))
      .subtracting(baseCrossings)
    #expect(
      afterOverlaps.count < baseOverlaps.count,
      "branching: expected to clear an overlap, got \(baseOverlaps.count)->\(afterOverlaps.count)"
    )
    #expect(
      afterAdded.isEmpty,
      "branching: the crossing-aware pass added crossings \(afterAdded.sorted())"
    )
  }

  @Test("stacked corridors spread by the route lane minimum")
  func stackedCorridorsSpreadByRouteLaneMinimum() {
    let prepared = PolicyCanvasPreparedRouteInput(
      input: PolicyCanvasRouteWorkerInput(nodes: [], groups: [], edges: [], fontScale: 1)
    )
    let routes = [
      "top": stackedCorridorRoute(sourceY: -80, targetY: 180, entryX: 40, exitX: 240),
      "middle": stackedCorridorRoute(sourceY: 0, targetY: 260, entryX: 60, exitX: 260),
      "bottom": stackedCorridorRoute(sourceY: 80, targetY: 340, entryX: 80, exitX: 280),
    ]

    let processed = PolicyCanvasOrthogonalNudgingRouteProcessing().processRoutes(
      input: PolicyCanvasRoutePostProcessingInput(prepared: prepared, routes: routes)
    )
    let corridorYs = processed.keys.sorted().compactMap { edgeID in
      processed[edgeID].flatMap(stackedCorridorY)
    }.sorted()

    #expect(corridorYs.count == routes.count)
    for pair in zip(corridorYs, corridorYs.dropFirst()) {
      #expect(pair.1 - pair.0 >= PolicyCanvasLayout.defaultEdgeLineSpacing - 0.001)
    }
  }

  @Test("nearby corridors spread by the route lane minimum")
  func nearbyCorridorsSpreadByRouteLaneMinimum() {
    let prepared = PolicyCanvasPreparedRouteInput(
      input: PolicyCanvasRouteWorkerInput(nodes: [], groups: [], edges: [], fontScale: 1)
    )
    let routes = [
      "top": stackedCorridorRoute(
        sourceY: -80, targetY: 180, entryX: 40, exitX: 240, corridorY: 100),
      "middle": stackedCorridorRoute(
        sourceY: 0, targetY: 260, entryX: 60, exitX: 260, corridorY: 106),
      "bottom": stackedCorridorRoute(
        sourceY: 80, targetY: 340, entryX: 80, exitX: 280, corridorY: 112),
    ]

    let processed = PolicyCanvasOrthogonalNudgingRouteProcessing().processRoutes(
      input: PolicyCanvasRoutePostProcessingInput(prepared: prepared, routes: routes)
    )
    let corridorYs = processed.keys.sorted().compactMap { edgeID in
      processed[edgeID].flatMap(stackedCorridorY)
    }.sorted()

    #expect(corridorYs.count == routes.count)
    for pair in zip(corridorYs, corridorYs.dropFirst()) {
      #expect(pair.1 - pair.0 >= PolicyCanvasLayout.defaultEdgeLineSpacing - 0.001)
    }
  }

  @Test("even corridor stacks anchor one route on the original lane")
  func evenCorridorStacksAnchorOneRouteOnOriginalLane() {
    let prepared = PolicyCanvasPreparedRouteInput(
      input: PolicyCanvasRouteWorkerInput(nodes: [], groups: [], edges: [], fontScale: 1)
    )
    let originalLane: CGFloat = 100
    let routes = [
      "upper": stackedCorridorRoute(
        sourceY: -80, targetY: 180, entryX: 40, exitX: 240, corridorY: originalLane),
      "lower": stackedCorridorRoute(
        sourceY: 80, targetY: 340, entryX: 80, exitX: 280, corridorY: originalLane),
    ]

    let processed = PolicyCanvasOrthogonalNudgingRouteProcessing().processRoutes(
      input: PolicyCanvasRoutePostProcessingInput(prepared: prepared, routes: routes)
    )
    let corridorYs = processed.keys.sorted().compactMap { edgeID in
      processed[edgeID].flatMap(stackedCorridorY)
    }.sorted()

    #expect(corridorYs.count == routes.count)
    #expect(
      corridorYs.contains { abs($0 - originalLane) < 0.001 },
      "expected one corridor to stay on the original lane, got \(corridorYs)"
    )
    for pair in zip(corridorYs, corridorYs.dropFirst()) {
      #expect(pair.1 - pair.0 >= PolicyCanvasLayout.defaultEdgeLineSpacing - 0.001)
    }
  }

  /// The greedy per-channel choice reads channels from a dictionary-grouped
  /// source, so it must sort everything it touches to stay order-independent.
  /// Routing the same laid-out graph with the edges fed forward and reversed must
  /// produce byte-identical routes under the preset.
  @Test("routing under the preset is independent of edge input order")
  func deterministicAcrossEdgeOrder() async throws {
    let nudged = Self.routeQualitySelection(
      routePostProcessing: PolicyCanvasAlgorithmDefaults.orthogonalNudgedRouteProcessing
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
        algorithmSelection: nudged
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

  /// A drag-end may bump the route generation, but routing identical graph input
  /// through fresh workers must still produce the same output. This catches
  /// accidental dictionary-order dependence without relying on the worker cache.
  @Test("routing under the preset is deterministic for identical input")
  func deterministicForIdenticalInput() async throws {
    let nudged = Self.routeQualitySelection(
      routePostProcessing: PolicyCanvasAlgorithmDefaults.orthogonalNudgedRouteProcessing
    )
    let sample = try #require(PolicyCanvasLabSamples.sample(id: "branching"))
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: sample.document, simulation: nil, audit: nil)
    viewModel.reflowLayout(preserveManualAnchors: false, force: true)
    let input = PolicyCanvasRouteWorkerInput(
      nodes: viewModel.nodes,
      groups: viewModel.groups,
      edges: viewModel.edges,
      fontScale: 1,
      routingHints: viewModel.routingHints,
      algorithmSelection: nudged
    )

    let first = await PolicyCanvasRouteWorker().compute(input: input)
    let second = await PolicyCanvasRouteWorker().compute(input: input)

    #expect(first == second)
  }

  // MARK: - Scene

  private struct Scene {
    let edges: [PolicyCanvasEdge]
    let routes: [String: PolicyCanvasEdgeRoute]
  }

  private static func routeQualitySelection(
    routePostProcessing: PolicyCanvasAlgorithmID
  ) -> PolicyCanvasAlgorithmSelection {
    PolicyCanvasAlgorithmSelection.referenceRouting
      .replacing(stage: .routePostProcessing, with: routePostProcessing)
      .replacing(
        stage: .labelPlacement,
        with: PolicyCanvasAlgorithmDefaults.polylineMidpointLabelPlacement
      )
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

  private func stackedCorridorRoute(
    sourceY: CGFloat,
    targetY: CGFloat,
    entryX: CGFloat,
    exitX: CGFloat,
    corridorY: CGFloat = 100
  ) -> PolicyCanvasEdgeRoute {
    let points = [
      CGPoint(x: 0, y: sourceY),
      CGPoint(x: entryX, y: sourceY),
      CGPoint(x: entryX, y: corridorY),
      CGPoint(x: exitX, y: corridorY),
      CGPoint(x: exitX, y: targetY),
      CGPoint(x: 320, y: targetY),
    ]
    return PolicyCanvasEdgeRoute(
      points: points,
      labelPosition: PolicyCanvasVisibilityRouter.labelPosition(for: points)
    )
  }

  private func stackedCorridorY(_ route: PolicyCanvasEdgeRoute) -> CGFloat? {
    policyCanvasRouteSegments(route)
      .dropFirst()
      .dropLast()
      .first { $0.isHorizontal && $0.length > 150 }
      .map(\.axisCoordinate)
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
      for rightSegment in right
      where leftSegment.sharesParallelCorridor(
        with: rightSegment,
        minimumSpacing: PolicyCanvasLayout.defaultEdgeLineSpacing
      ) {
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
      where policyCanvasRoutesProperlyCross(realized[left].route, realized[right].route) {
        crossings.append("\(realized[left].id) x \(realized[right].id)")
      }
    }
    return crossings
  }
}
