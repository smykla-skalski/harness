import CoreGraphics
import Foundation
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

/// Fan-in / fan-out channel quality. When several edges converge on one port (or
/// diverge from one port) their interior segments must run in distinct lanes -
/// never stacking collinearly on a shared corridor. The crossing-aware nudge
/// clears those stacks where a spread direction is free and declines where none
/// is, so it never adds an X-crossing or an overlap over the no-nudge baseline.
/// Measured on the reflowed group-free samples it is tuned against, simplest to
/// most complex.
@Suite("Policy canvas fan-in channel", .serialized)
@MainActor
struct PolicyCanvasFanInChannelTests {
  /// Reference routing policies, simplest -> stress-scale. Walking this ladder
  /// catches a routing change that helps one shape and regresses another without
  /// turning the route-quality gate into the full stress-catalog benchmark.
  private static let sampleIDs = PolicyCanvasReferenceAlgorithmSamples.ids

  /// Collinear overlap of an interior segment between two different edges, longer
  /// than this, reads as two wires stacked on one rail. Port stubs (first/last
  /// segment) are excluded because every wire legitimately shares the short
  /// perpendicular lead at its own port.
  private static let overlapThreshold: CGFloat = 8

  /// The crossing-aware nudge adds zero X-crossings on every sample: it scores
  /// each spread against the other routes and declines any that would push a
  /// riser through a foreign stub. No per-sample residual remains, so the budget
  /// is zero everywhere and any added crossing fails the gate.
  private static let addedCrossingBudget: [String: Int] = [:]

  @Test("converging rails never stack collinearly across reference lab samples")
  func convergingRailsNeverStackCollinearly() async throws {
    let baseline = Self.routeQualitySelection(
      routePostProcessing: PolicyCanvasAlgorithmDefaults.collinearRouteCompression
    )
    let nudged = Self.routeQualitySelection(
      routePostProcessing: PolicyCanvasAlgorithmDefaults.orthogonalNudgedRouteProcessing
    )
    var totals = ""
    var details = ""
    var overlapViolations: [String] = []
    var crossingViolations: [String] = []
    for sampleID in Self.sampleIDs {
      let before = try await routedScene(sampleID: sampleID, selection: baseline)
      let after = try await routedScene(sampleID: sampleID, selection: nudged)
      let beforeOverlaps = interiorOverlapPairs(routes: before.routes, edges: before.edges)
      let beforeCrossings = crossingPairs(routes: before.routes, edges: before.edges)
      let afterOverlaps = interiorOverlapPairs(routes: after.routes, edges: after.edges)
      let afterCrossings = crossingPairs(routes: after.routes, edges: after.edges)
      totals +=
        "\(sampleID): overlaps \(beforeOverlaps.count)->\(afterOverlaps.count)"
        + "  crossings \(beforeCrossings.count)->\(afterCrossings.count)\n"
      for entry in afterOverlaps.sorted() {
        details += "  \(sampleID) overlap \(entry)\n"
      }
      // Only the crossings the nudge introduces or removes - the pre-existing
      // ones are the router's, not ours, and listing the full set buries the
      // delta that "crossings not worse" actually turns on.
      let addedCrossings = Set(afterCrossings).subtracting(beforeCrossings).sorted()
      let removedCrossings = Set(beforeCrossings).subtracting(afterCrossings).sorted()
      for entry in addedCrossings {
        details += "  \(sampleID) ADDED cross \(entry)\n"
      }
      for entry in removedCrossings {
        details += "  \(sampleID) removed cross \(entry)\n"
      }

      // Primary guarantee: the nudge never stacks a new collinear overlap the
      // baseline did not already have.
      if afterOverlaps.count > beforeOverlaps.count {
        overlapViolations.append(
          "\(sampleID): added overlaps \(beforeOverlaps.count)->\(afterOverlaps.count) \(afterOverlaps)"
        )
      }
      // Secondary guarantee: the spread adds no X-crossing over the baseline.
      let budget = Self.addedCrossingBudget[sampleID, default: 0]
      if addedCrossings.count > budget {
        crossingViolations.append(
          "\(sampleID): added \(addedCrossings.count) > budget \(budget) - \(addedCrossings)"
        )
      }
    }
    // Written for the ongoing crossing work; the build-log expansions below
    // carry the same totals when the connected-device flake eats the file.
    writeReport("TOTALS\n\(totals)DETAILS\n\(details)", name: "fan-in-report.txt")

    let overlapDetail = overlapViolations.joined(separator: "\n")
    let crossingDetail = crossingViolations.joined(separator: "\n")
    #expect(
      overlapViolations.isEmpty,
      "the nudge stacked a new collinear overlap\n\(overlapDetail)\nTOTALS\n\(totals)"
    )
    #expect(
      crossingViolations.isEmpty,
      "the nudge added an X-crossing over the baseline\n\(crossingDetail)\nTOTALS\n\(totals)"
    )
  }

  @Test("dump fan group geometry for design")
  func dumpFanGroupGeometry() async throws {
    let baseline = Self.routeQualitySelection(
      routePostProcessing: PolicyCanvasAlgorithmDefaults.collinearRouteCompression
    )
    let nudged = Self.routeQualitySelection(
      routePostProcessing: PolicyCanvasAlgorithmDefaults.orthogonalNudgedRouteProcessing
    )
    var report = ""
    for sampleID in ["default", "multi-group", "extreme"] {
      let scene = try await routedScene(sampleID: sampleID, selection: nudged)
      let before = try await routedScene(sampleID: sampleID, selection: baseline)
      report += "===== \(sampleID) =====\n"
      report += "NODES:\n"
      for (nodeID, frame) in scene.nodeFrames.sorted(by: { $0.value.minY < $1.value.minY }) {
        report += "  \(nodeID) \(rect(frame))\n"
      }
      let fanIn = Dictionary(grouping: scene.edges, by: \.target).filter { $0.value.count > 1 }
      for (endpoint, members) in fanIn.sorted(by: { $0.key.nodeID < $1.key.nodeID }) {
        let frame = scene.nodeFrames[endpoint.nodeID] ?? .null
        report +=
          "FAN-IN target=\(endpoint.nodeID):\(endpoint.portID)"
          + " frame=\(rect(frame)) n=\(members.count)\n"
        for edge in members.sorted(by: { $0.id < $1.id }) {
          report += memberLine(edge: edge, scene: scene)
        }
      }
      let fanOut = Dictionary(grouping: scene.edges, by: \.source).filter { $0.value.count > 1 }
      for (endpoint, members) in fanOut.sorted(by: { $0.key.nodeID < $1.key.nodeID }) {
        let frame = scene.nodeFrames[endpoint.nodeID] ?? .null
        report +=
          "FAN-OUT source=\(endpoint.nodeID):\(endpoint.portID)"
          + " frame=\(rect(frame)) n=\(members.count)\n"
        for edge in members.sorted(by: { $0.id < $1.id }) {
          report += memberLine(edge: edge, scene: scene)
        }
      }
      // Node-level fans (members leave one node via different ports) are invisible
      // above; dump every edge - before (baseline) and after (nudged) - so the
      // crossings the nudge actually introduces can be traced by hand.
      report += "ALL EDGES (src node -> tgt node) [B=before, A=after]:\n"
      for edge in scene.edges.sorted(by: { $0.id < $1.id }) {
        report +=
          "  \(edge.id) \(edge.source.nodeID):\(edge.source.portID)"
          + " -> \(edge.target.nodeID):\(edge.target.portID)\n"
        report += "   B " + routePoints(edge: edge, scene: before)
        report += "   A " + routePoints(edge: edge, scene: scene)
      }
    }
    writeReport(report, name: "fan-geometry.txt")
    #expect(Bool(true))
  }

  private func memberLine(edge: PolicyCanvasEdge, scene: Scene) -> String {
    guard let route = scene.routes[edge.id] else {
      return "  \(edge.id): (no route)\n"
    }
    let pts = route.points
      .map { "(\(Int($0.x.rounded())),\(Int($0.y.rounded())))" }
      .joined(separator: " ")
    return "  \(edge.id) src=\(edge.source.nodeID): \(pts)\n"
  }

  private func routePoints(edge: PolicyCanvasEdge, scene: Scene) -> String {
    guard let route = scene.routes[edge.id] else {
      return "(no route)\n"
    }
    return route.points.map { "(\(Int($0.x.rounded())),\(Int($0.y.rounded())))" }
      .joined(separator: " ") + "\n"
  }

  private func rect(_ frame: CGRect) -> String {
    "[\(Int(frame.minX.rounded())),\(Int(frame.minY.rounded())) \(Int(frame.width.rounded()))x\(Int(frame.height.rounded()))]"
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

  // MARK: - Scene

  private struct Scene {
    let edges: [PolicyCanvasEdge]
    let routes: [String: PolicyCanvasEdgeRoute]
    let nodeFrames: [String: CGRect]
  }

  private func routedScene(
    sampleID: String,
    selection: PolicyCanvasAlgorithmSelection = .referenceRouting
  ) async throws -> Scene {
    let sample = try #require(PolicyCanvasLabSamples.sample(id: sampleID))
    // Strip groups so the layout/routing/nudging work on plain nodes + edges.
    // The group band layout is the structural cause of most overlaps and forced
    // crossings; with it gone we tune the algorithm against the bare graph.
    let document =
      PolicyCanvasLabSnapshotSupport.document(sample.document, includesGroups: false)
      ?? sample.document
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: document, simulation: nil, audit: nil)
    viewModel.reflowLayout(preserveManualAnchors: false, force: true)
    let edges = viewModel.edges
    let nodeFrames = Dictionary(
      uniqueKeysWithValues: viewModel.nodes.map { ($0.id, policyCanvasNodeFrame($0)) }
    )
    let input = PolicyCanvasRouteWorkerInput(
      nodes: viewModel.nodes,
      groups: viewModel.groups,
      edges: edges,
      fontScale: 1,
      routingHints: viewModel.routingHints,
      algorithmSelection: selection
    )
    let output = await PolicyCanvasRouteWorker().compute(input: input)
    return Scene(edges: edges, routes: output.routes, nodeFrames: nodeFrames)
  }

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
      // `overlap(with:)` returns the range overlap for same-axis segments; it
      // counts as a real corridor conflict when the lanes are closer than the
      // route-level minimum spacing.
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

  // MARK: - Report

  private func writeReport(_ contents: String, name: String) {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let worktreeRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let directory = worktreeRoot.appendingPathComponent("tmp/policy-canvas")
    try? FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    try? contents.write(
      to: directory.appendingPathComponent(name),
      atomically: true,
      encoding: .utf8
    )
  }
}
