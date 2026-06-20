import CoreGraphics
import Foundation
import HarnessMonitorKit
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

/// Regression gates and the deterministic dump for the graph-quality report,
/// run against every lab sample through the real routing pipeline.
@MainActor
struct PolicyCanvasGraphQualityGateTests {
  /// The largest stress fixtures stay in the deterministic debug dump and the
  /// lab-sample correctness tests, but not in the routine budget gate.
  private static let debugOnlyStressSampleIDs: Set<String> = [
    "extreme-matrix",
    "extreme-mesh",
    "extreme-lattice",
    "extreme-galaxy",
  ]

  private static var budgetedSamples: [PolicyCanvasLabSample] {
    PolicyCanvasLabSamples.all.filter { !debugOnlyStressSampleIDs.contains($0.id) }
  }

  private struct TimedRouteComputation {
    let output: PolicyCanvasPreparedRouteComputation
    let routeMs: Double
    let prepareMs: Double
    let passContextMs: Double
    let routeSelectionMs: Double
    let markerPlacementMs: Double
    let postProcessMs: Double
    let terminalsMs: Double
    let labelsMs: Double
    let boundsMs: Double
    let portVisibilityMs: Double
    let selectionPasses: Int
    let fastPath: Bool
  }

  private struct RoutedSample {
    let report: PolicyCanvasGraphQualityReport
    let nodes: [PolicyCanvasNode]
    let groups: [PolicyCanvasGroup]
    let edges: [PolicyCanvasEdge]
    let routes: [String: PolicyCanvasEdgeRoute]
    let portMarkerLayout: PolicyCanvasPortMarkerLayout
  }

  private static func nodesByID(_ nodes: [PolicyCanvasNode]) -> [String: PolicyCanvasNode] {
    Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
  }

  /// Route a lab sample exactly the way the lab renders it (load -> reflow ->
  /// route worker) and measure the resulting graph.
  func routedReport(sampleID: String) async throws -> PolicyCanvasGraphQualityReport {
    try await routedSample(sampleID: sampleID).report
  }

  private func routedSample(sampleID: String) async throws -> RoutedSample {
    let sample = try #require(PolicyCanvasLabSamples.sample(id: sampleID))
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: sample.document, simulation: nil, audit: nil)
    viewModel.reflowLayout(preserveManualAnchors: false, force: true)
    let input = PolicyCanvasRouteWorkerInput(
      nodes: viewModel.nodes,
      groups: viewModel.groups,
      edges: viewModel.edges,
      fontScale: 1,
      routingHints: viewModel.routingHints,
      precomputedRoutes: viewModel.precomputedRoutes,
      algorithmSelection: .referenceRouting
    )
    let output = await PolicyCanvasRouteWorker().compute(input: input)
    let report = policyCanvasMeasureGraphQuality(
      nodes: viewModel.nodes,
      groups: viewModel.groups,
      edges: viewModel.edges,
      routes: output.routes,
      labelPositions: output.labelPositions,
      portMarkerLayout: output.portMarkerLayout
    )
    return RoutedSample(
      report: report,
      nodes: viewModel.nodes,
      groups: viewModel.groups,
      edges: viewModel.edges,
      routes: output.routes,
      portMarkerLayout: output.portMarkerLayout
    )
  }

  /// Routing must be canonical: the geometry a sample produces cannot depend on
  /// the order its nodes and edges arrive in. The route worker keys and sorts by
  /// stable IDs throughout, so reversing the input arrays must yield byte-identical
  /// routes. This is the determinism property a single-process unit test can hold
  /// without flaking; cross-process Swift-hash-seed independence was verified
  /// out of band by routing every budgeted sample under several randomized hash
  /// seeds and getting identical geometry each time. Together they keep the budget
  /// gate above stable run to run instead of flickering whenever an unordered Set
  /// or Dictionary iteration leaks into route geometry.
  @Test func routeGeometryIsInputOrderInvariant() async throws {
    for sample in Self.budgetedSamples {
      let document = try #require(PolicyCanvasLabSamples.sample(id: sample.id)).document
      let viewModel = PolicyCanvasViewModel.sample()
      viewModel.load(document: document, simulation: nil, audit: nil)
      viewModel.reflowLayout(preserveManualAnchors: false, force: true)
      func routedGeometry(reversedInput: Bool) async -> String {
        let input = PolicyCanvasRouteWorkerInput(
          nodes: reversedInput ? Array(viewModel.nodes.reversed()) : viewModel.nodes,
          groups: reversedInput ? Array(viewModel.groups.reversed()) : viewModel.groups,
          edges: reversedInput ? Array(viewModel.edges.reversed()) : viewModel.edges,
          fontScale: 1,
          routingHints: viewModel.routingHints,
          precomputedRoutes: viewModel.precomputedRoutes,
          algorithmSelection: .referenceRouting
        )
        let routes = await PolicyCanvasRouteWorker().compute(input: input).routes
        return
          routes
          .sorted { $0.key < $1.key }
          .map { id, route in
            id + "="
              + route.points
              .map { "\(Int(($0.x * 1_000).rounded())),\(Int(($0.y * 1_000).rounded()))" }
              .joined(separator: ">")
          }
          .joined(separator: ";")
      }
      let natural = await routedGeometry(reversedInput: false)
      let reversed = await routedGeometry(reversedInput: true)
      #expect(
        natural == reversed,
        "\(sample.id): route geometry changed when node/edge input order was reversed - an unordered Set or Dictionary is leaking into routing"
      )
    }
  }

  /// Reference all-nodes scan for body hits: the implementation the spatial
  /// index replaced. The indexed measure must return exactly this set for every
  /// sample, so this stays as the equivalence oracle.
  private static func bruteForceBodyHits(
    routedEdges: [PolicyCanvasRoutedEdge],
    nodeFramesByID: [String: CGRect],
    groupTitleFrames: [(id: String, frame: CGRect)]
  ) -> [PolicyCanvasBodyHitViolation] {
    var violations: [PolicyCanvasBodyHitViolation] = []
    let sortedNodes = nodeFramesByID.sorted { $0.key < $1.key }
    for routed in routedEdges {
      let endpoints: Set<String> = [routed.edge.source.nodeID, routed.edge.target.nodeID]
      for (nodeID, frame) in sortedNodes where !endpoints.contains(nodeID) {
        if policyCanvasRouteIntersectsObstacles(routed.route, obstacles: [frame]) {
          violations.append(
            PolicyCanvasBodyHitViolation(
              edgeID: routed.edge.id, obstacle: .node, obstacleID: nodeID, frame: frame))
        }
      }
      for title in groupTitleFrames
      where policyCanvasRouteIntersectsObstacles(routed.route, obstacles: [title.frame]) {
        violations.append(
          PolicyCanvasBodyHitViolation(
            edgeID: routed.edge.id, obstacle: .groupTitle, obstacleID: title.id, frame: title.frame))
      }
    }
    return violations.sorted { lhs, rhs in
      if lhs.edgeID != rhs.edgeID {
        return lhs.edgeID < rhs.edgeID
      }
      if lhs.obstacle != rhs.obstacle {
        return lhs.obstacle.rawValue < rhs.obstacle.rawValue
      }
      return lhs.obstacleID < rhs.obstacleID
    }
  }

  /// Reference full per-edge scan for terminal side mismatches: the measure the
  /// incremental baseline fold must reproduce for any candidate. Each endpoint
  /// that routes into a side other than its resolved port side counts once.
  private static func fullSideMismatchCount(
    edges: [PolicyCanvasEdge], routes: [String: PolicyCanvasEdgeRoute]
  ) -> Int {
    var count = 0
    for edge in edges {
      guard let route = routes[edge.id] else { continue }
      if policyCanvasRouteSourceSide(route) != policyCanvasResolvedPortSide(for: edge.source) {
        count += 1
      }
      if policyCanvasRouteTargetSide(route) != policyCanvasResolvedPortSide(for: edge.target) {
        count += 1
      }
    }
    return count
  }

  /// The incremental repair-measurement baseline must return exactly the same
  /// body-hit count and crossed-port violations as a full re-measure, for any
  /// candidate that perturbs a few edges. The crossed-port repair feeds it
  /// hundreds of small perturbations per pass; if the fold-in ever diverged from
  /// the full measure, the repair would accept or reject the wrong candidate and
  /// the graph-quality budgets would shift silently. Perturbations here swap and
  /// reverse routes so terminals move sides and geometry changes, exercising the
  /// affected-node-side recompute and the per-edge body-hit fold.
  @Test func incrementalRepairBaselineMatchesFullMeasure() async throws {
    var exercised: [String] = []
    var mismatches: [String] = []
    for sample in PolicyCanvasLabSamples.all {
      let routed = try await routedSample(sampleID: sample.id)
      let nodeSizes = PolicyCanvasLayout.nodeSizes(for: routed.nodes, edges: routed.edges)
      var nodeFramesByID: [String: CGRect] = [:]
      for node in routed.nodes {
        nodeFramesByID[node.id] = CGRect(
          origin: node.position,
          size: nodeSizes[node.id] ?? PolicyCanvasLayout.nodeSize(for: node))
      }
      let groupTitleFrames = policyCanvasGroupTitleFramesByID(routed.groups)
      let nodeFrameIndex = PolicyCanvasNodeFrameIndex(framesByID: nodeFramesByID)
      let baseline = PolicyCanvasRepairMeasurementBaseline(
        edges: routed.edges, referenceRoutes: routed.routes, nodeFramesByID: nodeFramesByID,
        groupTitleFrames: groupTitleFrames, nodeFrameIndex: nodeFrameIndex)
      exercised.append(sample.id)
      let edgeIDs = routed.edges.map(\.id)
      guard edgeIDs.count >= 2 else { continue }
      // Deterministic perturbations: single-edge swap, single-edge reverse, and
      // a two-edge swap, sampled across the edge list.
      let stride = max(1, edgeIDs.count / 12)
      for index in Swift.stride(from: 0, to: edgeIDs.count, by: stride) {
        let otherIndex = (index + 1) % edgeIDs.count
        let edgeA = edgeIDs[index]
        let edgeB = edgeIDs[otherIndex]
        guard let routeA = routed.routes[edgeA], let routeB = routed.routes[edgeB] else { continue }
        let reversedA = PolicyCanvasEdgeRoute(
          points: Array(routeA.points.reversed()),
          labelPosition: PolicyCanvasVisibilityRouter.labelPosition(
            for: Array(routeA.points.reversed())))
        let candidates: [(routes: [String: PolicyCanvasEdgeRoute], changed: Set<String>)] = [
          (routed.routes.merging([edgeA: routeB]) { _, new in new }, [edgeA]),
          (routed.routes.merging([edgeA: reversedA]) { _, new in new }, [edgeA]),
          (
            routed.routes.merging([edgeA: routeB, edgeB: routeA]) { _, new in new },
            [edgeA, edgeB]
          ),
        ]
        for (candidateRoutes, changed) in candidates {
          let fullRoutedEdges = routed.edges.compactMap { edge -> PolicyCanvasRoutedEdge? in
            guard let route = candidateRoutes[edge.id], route.points.count >= 2 else { return nil }
            return PolicyCanvasRoutedEdge(edge: edge, route: route)
          }
          let fullBody = policyCanvasMeasureBodyHits(
            routedEdges: fullRoutedEdges, nodeFramesByID: nodeFramesByID,
            groupTitleFrames: groupTitleFrames, nodeFrameIndex: nodeFrameIndex
          ).count
          let incrementalBody = baseline.bodyHitTotal(
            forCandidate: candidateRoutes, changedEdges: changed)
          if fullBody != incrementalBody {
            mismatches.append(
              "\(sample.id):\(changed):body full=\(fullBody) incr=\(incrementalBody)")
          }
          let fullHitEdges = Set(
            policyCanvasMeasureBodyHits(
              routedEdges: fullRoutedEdges, nodeFramesByID: nodeFramesByID,
              groupTitleFrames: groupTitleFrames, nodeFrameIndex: nodeFrameIndex
            ).map(\.edgeID))
          let incrementalHitEdges = baseline.bodyHitEdges(
            forCandidate: candidateRoutes, changedEdges: changed)
          if fullHitEdges != incrementalHitEdges {
            mismatches.append(
              "\(sample.id):\(changed):hitEdges full=\(fullHitEdges.count) incr=\(incrementalHitEdges.count)")
          }
          let fullCrossed = policyCanvasMeasureCrossedPorts(
            routedEdges: fullRoutedEdges, nodeFramesByID: nodeFramesByID)
          let incrementalCrossed = baseline.crossedViolations(
            forCandidate: candidateRoutes, changedEdges: changed)
          if fullCrossed != incrementalCrossed {
            mismatches.append(
              "\(sample.id):\(changed):crossed full=\(fullCrossed.count) incr=\(incrementalCrossed.count)")
          }
          let fullSide = Self.fullSideMismatchCount(
            edges: routed.edges, routes: candidateRoutes)
          let incrementalSide = baseline.sideMismatchTotal(
            forCandidate: candidateRoutes, changedEdges: changed)
          if fullSide != incrementalSide {
            mismatches.append(
              "\(sample.id):\(changed):side full=\(fullSide) incr=\(incrementalSide)")
          }
        }
      }
    }
    #expect(
      exercised.contains("extreme-galaxy"),
      "the largest sample must exercise the incremental baseline; got \(exercised)")
    #expect(
      mismatches.isEmpty,
      "incremental repair measurement must equal the full measure: \(mismatches.prefix(20))")
  }

  /// The spatial-index body-hit measure must return exactly the violations the
  /// brute-force all-nodes scan returns, for every lab sample including the
  /// largest. The repair chain calls the measure hundreds of times, so the index
  /// is the performance lever; this gate proves it only changes speed, never the
  /// measured set, so no graph-quality budget can shift underneath it.
  @Test func indexedBodyHitsMatchBruteForceScan() async throws {
    var exercised: [String] = []
    var mismatches: [String] = []
    for sample in PolicyCanvasLabSamples.all {
      let routed = try await routedSample(sampleID: sample.id)
      let nodeSizes = PolicyCanvasLayout.nodeSizes(for: routed.nodes, edges: routed.edges)
      var nodeFramesByID: [String: CGRect] = [:]
      for node in routed.nodes {
        nodeFramesByID[node.id] = CGRect(
          origin: node.position,
          size: nodeSizes[node.id] ?? PolicyCanvasLayout.nodeSize(for: node))
      }
      let groupTitleFrames = policyCanvasGroupTitleFramesByID(routed.groups)
      let routedEdges = routed.edges.compactMap { edge -> PolicyCanvasRoutedEdge? in
        guard let route = routed.routes[edge.id], route.points.count >= 2 else {
          return nil
        }
        return PolicyCanvasRoutedEdge(edge: edge, route: route)
      }
      let indexed = policyCanvasMeasureBodyHits(
        routedEdges: routedEdges, nodeFramesByID: nodeFramesByID,
        groupTitleFrames: groupTitleFrames)
      let brute = Self.bruteForceBodyHits(
        routedEdges: routedEdges, nodeFramesByID: nodeFramesByID,
        groupTitleFrames: groupTitleFrames)
      exercised.append(sample.id)
      if indexed != brute {
        mismatches.append("\(sample.id): indexed=\(indexed.count) brute=\(brute.count)")
      }
    }
    #expect(
      exercised.contains("extreme-galaxy"),
      "the largest sample must exercise the body-hit equivalence gate; got \(exercised)")
    #expect(
      mismatches.isEmpty,
      "indexed body-hit measure must equal the brute-force scan exactly: \(mismatches)")
  }

  /// Per-sample regression gate across the routine lab samples: each gated
  /// category must stay at or below its budget. Budgets are today's measured
  /// values, so any layout or routing change that makes a sample worse fails
  /// here; improvements just leave headroom (drop the budget once a lower count
  /// is banked). A budgeted sample with no budget entry gets all-zero budgets and
  /// fails until its baseline is captured.
  ///
  /// This loops every sample inside one test rather than using a parametrized
  /// `@Test(arguments:)`: parametrized swift-testing cases are not matched by the
  /// `-only-testing` selector the build runs with, so a parametrized gate is
  /// silently skipped. `#expect` records each violation independently and keeps
  /// going, so a single run still reports every offending (sample, category) pair.
  @Test func allSamplesStayWithinBudget() async throws {
    for sample in Self.budgetedSamples {
      let report = try await routedReport(sampleID: sample.id)
      for category in PolicyCanvasQualityCategory.allCases where category.isGated {
        let actual = report.count(for: category)
        let budget = PolicyCanvasGraphQualityBudgets.limit(category, forSampleID: sample.id)
        #expect(
          actual <= budget,
          "\(sample.id): \(category.label) = \(actual) exceeds budget \(budget)"
        )
      }
    }
  }

  @Test func budgetGateSkipsOnlyLargestStressSamples() {
    let allSampleIDs = PolicyCanvasLabSamples.all.map(\.id)
    let budgetedSampleIDs = Self.budgetedSamples.map(\.id)

    #expect(Self.debugOnlyStressSampleIDs.count == 4)
    #expect(Self.debugOnlyStressSampleIDs.isSubset(of: Set(allSampleIDs)))
    #expect(
      budgetedSampleIDs
        == allSampleIDs.filter {
          !Self.debugOnlyStressSampleIDs.contains($0)
        })
    #expect(budgetedSampleIDs.contains("extreme"))
    #expect(budgetedSampleIDs.contains("extreme-braid"))
    #expect(!budgetedSampleIDs.contains("extreme-matrix"))
    #expect(!budgetedSampleIDs.contains("extreme-galaxy"))
  }

  @Test func extremeGalaxyPrecomputedRoutesAvoidBodyHits() async throws {
    let report = try await routedReport(sampleID: "extreme-galaxy")
    #expect(
      report.bodyHits.isEmpty,
      """
      extreme-galaxy precomputed routes should not pass through node or group-title bodies
      bodyHits=\(Self.bodyHitDetail(report))
      """
    )
  }

  /// The rendered port-marker dot must sit at the wire's along-side position. The
  /// route worker fans wires through a crossing-minimal optimized port order, but
  /// the canvas and the detachment detector draw each dot at its declaration-order
  /// anchor. The final marker layout must therefore measure each terminal's axis
  /// offset from the declaration-order anchor, so the dot lands on the wire end
  /// along the side instead of floating off by the optimized-vs-declaration gap.
  /// `extreme-galaxy` ships precomputed routes whose gate node reorders its output
  /// ports, so it exercises the case the desync first surfaced on.
  ///
  /// This is the along-side axis only: perpendicular detachment (a wire that does
  /// not reach the node edge at all) is a routing concern the marker offset cannot
  /// express, so it stays out of scope here.
  @Test func renderedPortMarkersSitOnWiresAlongSide() async throws {
    let routed = try await routedSample(sampleID: "extreme-galaxy")
    var offenders: [String] = []
    for edge in routed.edges {
      for (role, endpoint, point) in [
        (PolicyCanvasRouteEndpointRole.source, edge.source, routed.routes[edge.id]?.points.first),
        (PolicyCanvasRouteEndpointRole.target, edge.target, routed.routes[edge.id]?.points.last),
      ] {
        guard
          let point,
          let terminal = routed.portMarkerLayout.terminal(edgeID: edge.id, role: role),
          let center = policyCanvasPortMarkerCenter(
            endpoint: endpoint,
            terminal: terminal,
            nodesByID: Self.nodesByID(routed.nodes),
            nodeSizes: PolicyCanvasLayout.nodeSizes(for: routed.nodes, edges: routed.edges)
          )
        else {
          continue
        }
        let alongSide =
          (terminal.side == .leading || terminal.side == .trailing)
          ? abs(point.y - center.y)
          : abs(point.x - center.x)
        if alongSide > 0.5 {
          offenders.append("\(edge.id):\(role):\(terminal.side.rawValue):alongSide=\(alongSide)")
        }
      }
    }
    #expect(
      offenders.isEmpty,
      "rendered port dots should sit on their wire along the side: \(offenders.prefix(40))"
    )
  }

  /// The wire must also reach its port dot on the perpendicular axis: a precomputed
  /// route can terminate one routing channel outward from the node edge (right side
  /// and correct along-side coordinate, but offset in x for a trailing port), so the
  /// wire visibly ends in empty space short of the dot. The terminal-reach pass
  /// extends each terminal inward to the node-edge anchor when that stub adds no
  /// node-body crossing, closing the perpendicular gap the marker offset cannot
  /// express. Checked across every precomputed stress sample.
  @Test func renderedPortMarkersReachWiresPerpendicular() async throws {
    var offenders: [String] = []
    for sampleID in ["extreme-galaxy", "extreme-mesh", "extreme-lattice", "extreme"] {
      let routed = try await routedSample(sampleID: sampleID)
      let nodesByID = Self.nodesByID(routed.nodes)
      let nodeSizes = PolicyCanvasLayout.nodeSizes(for: routed.nodes, edges: routed.edges)
      for edge in routed.edges {
        for (role, endpoint, point) in [
          (PolicyCanvasRouteEndpointRole.source, edge.source, routed.routes[edge.id]?.points.first),
          (PolicyCanvasRouteEndpointRole.target, edge.target, routed.routes[edge.id]?.points.last),
        ] {
          guard
            let point,
            let terminal = routed.portMarkerLayout.terminal(edgeID: edge.id, role: role),
            let center = policyCanvasPortMarkerCenter(
              endpoint: endpoint, terminal: terminal,
              nodesByID: nodesByID, nodeSizes: nodeSizes)
          else { continue }
          let perpendicular =
            (terminal.side == .leading || terminal.side == .trailing)
            ? abs(point.x - center.x)
            : abs(point.y - center.y)
          if perpendicular > 0.5 {
            offenders.append("\(sampleID):\(edge.id):\(role):perp=\(perpendicular)")
          }
        }
      }
    }
    #expect(
      offenders.isEmpty,
      "rendered port dots should reach their wire perpendicular: \(offenders.count) - \(offenders.prefix(20))"
    )
  }

  @Test func allSamplesAvoidCrossedPorts() async throws {
    var violations: [String] = []
    for sample in PolicyCanvasLabSamples.all {
      let routed = try await routedSample(sampleID: sample.id)
      guard !routed.report.crossedPorts.isEmpty else {
        continue
      }
      violations.append(
        [
          "\(sample.id): \(routed.report.count(for: .crossedPorts)) crossed ports",
          Self.crossedPortDetail(routed.report),
          Self.crossedPortRouteDetail(routed.report, routes: routed.routes),
        ].joined(separator: " - ")
      )
    }
    #expect(
      violations.isEmpty,
      """
      lab sample routes should not attach ports in crossed order
      violations=\(violations.joined(separator: "\n"))
      """
    )
  }

  @Test func allSamplesKeepRouteTerminalsOnSemanticSides() async throws {
    var violations: [String] = []
    for sample in PolicyCanvasLabSamples.all {
      let routed = try await routedSample(sampleID: sample.id)
      for edge in routed.edges {
        guard let route = routed.routes[edge.id] else {
          violations.append("\(sample.id):\(edge.id): missing route")
          continue
        }
        violations.append(
          contentsOf: Self.semanticTerminalSideViolations(
            sampleID: sample.id,
            edge: edge,
            route: route,
            markerLayout: routed.portMarkerLayout
          )
        )
      }
    }
    #expect(
      violations.isEmpty,
      """
      lab sample route terminals should stay on left input and right output sides
      violations=\(violations.joined(separator: "\n"))
      """
    )
  }

  @Test func allSamplesAvoidReusedCorridors() async throws {
    var violations: [String] = []
    for sample in PolicyCanvasLabSamples.all {
      let report = try await routedReport(sampleID: sample.id)
      let count = report.count(for: .corridorReuse)
      guard count > 0 else {
        continue
      }
      violations.append(
        "\(sample.id): \(count) reused corridors - \(Self.corridorReuseDetail(report))"
      )
    }
    #expect(
      violations.isEmpty,
      """
      lab sample routes should not reuse exact same-axis corridors
      violations=\(violations.joined(separator: "\n"))
      """
    )
  }

  @Test func allSamplesAvoidParallelCorridors() async throws {
    var violations: [String] = []
    for sample in PolicyCanvasLabSamples.all {
      let routed = try await routedSample(sampleID: sample.id)
      let count = routed.report.count(for: .corridorParallel)
      guard count > 0 else {
        continue
      }
      violations.append(
        [
          "\(sample.id): \(count) parallel corridors",
          Self.corridorParallelDetail(routed.report),
          Self.corridorParallelRouteDetail(routed.report, routes: routed.routes),
        ].joined(separator: " - ")
      )
    }
    #expect(
      violations.isEmpty,
      """
      lab sample routes should keep parallel corridors at least one lane apart
      violations=\(violations.joined(separator: "\n"))
      """
    )
  }

  @Test func allSamplesKeepRouteSegmentsOnGrid() async throws {
    var violations: [String] = []
    for sample in PolicyCanvasLabSamples.all {
      let routed = try await routedSample(sampleID: sample.id)
      let count = routed.report.count(for: .routeSegments)
      guard count > 0 else {
        continue
      }
      violations.append(
        [
          "\(sample.id): \(count) short or off-grid route segments",
          Self.routeSegmentDetail(routed.report),
        ].joined(separator: " - ")
      )
    }
    #expect(
      violations.isEmpty,
      """
      lab sample route segments should be at least one grid step and a grid multiple
      violations=\(violations.joined(separator: "\n"))
      """
    )
  }

  /// Deterministic dump of every sample's report to
  /// `tmp/policy-canvas/graph-quality-baseline.txt` (resolved from `#filePath`,
  /// matching the fan-in dump convention). Captures the baseline used to set the
  /// per-sample gate budgets and serves as the standing graph-quality snapshot.
  @Test func dumpAllSampleReports() async throws {
    var lines: [String] = []
    for sample in PolicyCanvasLabSamples.all {
      let report = try await routedReport(sampleID: sample.id)
      lines.append("## \(sample.id) (\(sample.name))")
      for headline in report.headlines {
        lines.append("  \(headline.label): \(headline.value)")
      }
      lines.append("  max edge length: \(Int(report.edgeLengths.maxLength.rounded()))")
      lines.append("  total bends: \(report.edgeLengths.totalBends)")
      lines.append("  occupancy: \(String(format: "%.3f", report.bounds.nodeOccupancyRatio))")
      lines.append("")
    }
    writeReport(lines.joined(separator: "\n"), name: "graph-quality-baseline.txt")
    #expect(!PolicyCanvasLabSamples.all.isEmpty)
  }

  @Test func dumpExtremeGalaxyPerformanceReport() async throws {
    let sample = try #require(PolicyCanvasLabSamples.sample(id: "extreme-galaxy"))
    let viewModel = PolicyCanvasViewModel.sample()
    let loadStart = Date()
    viewModel.load(document: sample.document, simulation: nil, audit: nil)
    let loadMs = Date().timeIntervalSince(loadStart) * 1_000
    let componentGraphStart = Date()
    let componentGraph = policyCanvasLoadedGraph(
      from: sample.document,
      policyGroupTitle: nil
    )
    let componentGraphMs = Date().timeIntervalSince(componentGraphStart) * 1_000
    let componentCleanStart = Date()
    let componentClean = policyCanvasCleanInitialLayout(
      nodes: componentGraph.nodes,
      groups: componentGraph.groups,
      edges: componentGraph.mappedEdges
    )
    let componentCleanMs = Date().timeIntervalSince(componentCleanStart) * 1_000
    let componentFoldStart = Date()
    let componentFoldedEdges = policyCanvasFoldParallelBranches(componentGraph.mappedEdges)
    let componentFoldMs = Date().timeIntervalSince(componentFoldStart) * 1_000
    let componentSideStart = Date()
    let componentNodeLookup = PolicyCanvasNodeLookup(nodes: componentClean.nodes)
    let componentEdges = componentFoldedEdges.map { edge in
      policyCanvasApplyingPreferredPortSides(edge, nodeLookup: componentNodeLookup)
    }
    let componentSideMs = Date().timeIntervalSince(componentSideStart) * 1_000
    try writeReport(
      elkBenchmarkGraphJSON(nodes: viewModel.nodes, edges: viewModel.edges),
      name: "extreme-galaxy-elk-input.json"
    )
    try writeReport(
      elkBenchmarkGraphJSON(nodes: viewModel.nodes, edges: viewModel.edges, includesPorts: true),
      name: "extreme-galaxy-elk-ports-input.json"
    )

    let layoutStart = Date()
    viewModel.reflowLayout(preserveManualAnchors: false, force: true)
    let layoutMs = Date().timeIntervalSince(layoutStart) * 1_000
    let plannedViewModel = PolicyCanvasViewModel.sample()
    plannedViewModel.load(document: sample.document, simulation: nil, audit: nil)
    let plannedStart = Date()
    let plannedGraph = plannedViewModel.plannedReflowGraph(
      preserveManualAnchors: false,
      force: true
    )
    let plannedMs = Date().timeIntervalSince(plannedStart) * 1_000
    let plannedCommitStart = Date()
    if let plannedGraph {
      plannedViewModel.commitPlannedReflowGraph(
        plannedGraph,
        preserveManualAnchors: false,
        force: true,
        requestsRouteComputation: false
      )
    }
    let plannedCommitMs = Date().timeIntervalSince(plannedCommitStart) * 1_000
    let elkProbeStart = Date()
    let elkProbe = policyCanvasElkLayoutResult(
      nodes: viewModel.nodes,
      groups: viewModel.groups,
      edges: viewModel.edges,
      mode: .explicitReflow(preserveManualAnchors: false)
    )
    let elkProbeMs = Date().timeIntervalSince(elkProbeStart) * 1_000
    var elkProbeAppliedRoutes = -1
    var elkProbeOverlapCleanup = false
    var elkProbeSingleFedAlignment = false
    var elkProbeAttachFailure = "none"
    if let elkProbe {
      var probeNodes = viewModel.nodes
      var probeGroups = viewModel.groups
      _ = applyPolicyCanvasLayoutResult(
        elkProbe,
        nodes: &probeNodes,
        groups: &probeGroups,
        centerInMinimumCanvas: true
      )
      var probePrecomputed = policyCanvasAppliedPrecomputedRoutes(
        result: elkProbe,
        nodes: probeNodes,
        edges: viewModel.edges
      )
      if probePrecomputed == nil {
        elkProbeAttachFailure = Self.precomputedAttachFailure(
          result: elkProbe,
          nodes: probeNodes,
          edges: viewModel.edges
        )
      }
      if policyCanvasUsesSingleFedTerminalAlignment(viewModel.algorithmSelection) {
        elkProbeSingleFedAlignment = true
        policyCanvasAlignSingleFedTerminals(
          nodes: &probeNodes,
          groups: &probeGroups,
          edges: viewModel.edges
        )
      }
      if policyCanvasResolveGroupedNodeOverlaps(
        nodes: &probeNodes,
        groups: &probeGroups
      ) {
        elkProbeOverlapCleanup = true
        probePrecomputed = nil
      }
      elkProbeAppliedRoutes = probePrecomputed?.routes.count ?? -1
    }

    let input = PolicyCanvasRouteWorkerInput(
      nodes: viewModel.nodes,
      groups: viewModel.groups,
      edges: viewModel.edges,
      fontScale: 1,
      routingHints: viewModel.routingHints,
      precomputedRoutes: viewModel.precomputedRoutes,
      algorithmSelection: .referenceRouting
    )
    let timedRoute = measuredRouteComputation(input: input)

    let qualityStart = Date()
    let report = policyCanvasMeasureGraphQuality(
      nodes: viewModel.nodes,
      groups: viewModel.groups,
      edges: viewModel.edges,
      routes: timedRoute.output.routes,
      labelPositions: timedRoute.output.labelPositions,
      portMarkerLayout: timedRoute.output.portMarkerLayout
    )
    let qualityMs = Date().timeIntervalSince(qualityStart) * 1_000

    let contents = [
      "sample: \(sample.id) (\(sample.name))",
      "nodes: \(viewModel.nodes.count)",
      "edges: \(viewModel.edges.count)",
      "groups: \(viewModel.groups.count)",
      String(format: "component_graph_ms: %.3f", componentGraphMs),
      String(format: "component_clean_ms: %.3f", componentCleanMs),
      String(format: "component_fold_ms: %.3f", componentFoldMs),
      String(format: "component_side_ms: %.3f", componentSideMs),
      "component_edges: \(componentEdges.count)",
      String(format: "load_ms: %.3f", loadMs),
      String(format: "layout_ms: %.3f", layoutMs),
      String(format: "planned_reflow_ms: %.3f", plannedMs),
      String(format: "planned_commit_ms: %.3f", plannedCommitMs),
      "planned_precomputed_routes: \(plannedGraph?.precomputedRoutes?.routes.count ?? -1)",
      "algorithm_harness_current: \(PolicyCanvasLayoutAlgorithmRegistry.isHarnessCurrentLayout(viewModel.algorithmSelection))",
      "algorithm_cache: \(viewModel.algorithmSelection.cacheIdentity)",
      String(format: "elk_probe_ms: %.3f", elkProbeMs),
      "elk_probe_routes: \(elkProbe?.precomputedRoutes?.routes.count ?? -1)",
      "elk_probe_applied_routes: \(elkProbeAppliedRoutes)",
      "elk_probe_attach_failure: \(elkProbeAttachFailure)",
      "elk_probe_single_fed_alignment: \(elkProbeSingleFedAlignment)",
      "elk_probe_overlap_cleanup: \(elkProbeOverlapCleanup)",
      "view_model_precomputed_routes: \(viewModel.precomputedRoutes?.routes.count ?? -1)",
      String(format: "route_ms: %.3f", timedRoute.routeMs),
      String(format: "route_prepare_ms: %.3f", timedRoute.prepareMs),
      String(format: "route_pass_context_ms: %.3f", timedRoute.passContextMs),
      String(format: "route_selection_ms: %.3f", timedRoute.routeSelectionMs),
      String(format: "route_marker_placement_ms: %.3f", timedRoute.markerPlacementMs),
      String(format: "route_post_process_ms: %.3f", timedRoute.postProcessMs),
      String(format: "route_terminals_ms: %.3f", timedRoute.terminalsMs),
      String(format: "route_labels_ms: %.3f", timedRoute.labelsMs),
      String(format: "route_bounds_ms: %.3f", timedRoute.boundsMs),
      String(format: "route_port_visibility_ms: %.3f", timedRoute.portVisibilityMs),
      "route_selection_passes: \(timedRoute.selectionPasses)",
      "route_fast_path: \(timedRoute.fastPath)",
      String(format: "quality_report_ms: %.3f", qualityMs),
      "port_overlaps: \(report.count(for: .portOverlaps))",
      "port_detached: \(report.count(for: .portDetached))",
      "label_overlaps: \(report.count(for: .labelOverlaps))",
      "route_segments: \(report.count(for: .routeSegments))",
      "route_segment_detail: \(Self.routeSegmentDetail(report))",
      "corridor_parallel: \(report.count(for: .corridorParallel))",
      "corridor_parallel_detail: \(Self.corridorParallelDetail(report))",
      "corridor_parallel_route_detail: \(Self.corridorParallelRouteDetail(report, routes: timedRoute.output.routes))",
      "corridor_reuse: \(report.count(for: .corridorReuse))",
      "corridor_reuse_route_detail: \(Self.corridorReuseRouteDetail(report, routes: timedRoute.output.routes))",
      "body_hits: \(report.count(for: .bodyHits))",
      "body_hit_detail: \(Self.bodyHitDetail(report))",
      "body_hit_route_detail: \(Self.bodyHitRouteDetail(report, routes: timedRoute.output.routes))",
      "crossed_ports: \(report.count(for: .crossedPorts))",
      "crossed_port_detail: \(Self.crossedPortDetail(report))",
      "crossed_port_route_detail: \(Self.crossedPortRouteDetail(report, routes: timedRoute.output.routes))",
      "port_hotspots: \(Self.portSpacingHotspots(report))",
      "port_detail: \(Self.portSpacingDetail(report, matching: "xg-m10-action-gate"))",
      "elk_endpoint_sides: \(Self.elkEndpointSides(input.edges, edgePrefix: "xge:m10-gate-"))",
      "elk_route_detail: \(Self.routeDetail(elkProbe?.precomputedRoutes?.routes ?? [:], edgePrefix: "xge:m10-gate-"))",
      "route_detail: \(Self.routeDetail(timedRoute.output.routes, edgePrefix: "xge:m10-gate-"))",
    ].joined(separator: "\n")
    writeReport(contents, name: "extreme-galaxy-performance.txt")
    #expect(timedRoute.output.routes.count == viewModel.edges.count)
    #expect(plannedGraph?.precomputedRoutes?.routes.count == viewModel.edges.count)
    #expect(viewModel.precomputedRoutes?.routes.count == viewModel.edges.count)
    #expect(timedRoute.fastPath)

    let scenario = PolicyCanvasTerminalScenario(
      viewModel: viewModel,
      edges: viewModel.edges,
      routes: timedRoute.output.routes
    )
    let assertions = PolicyCanvasTerminalAssertions()
    assertions.assertMarkerOffsets(
      scenario: scenario,
      markerLayout: timedRoute.output.portMarkerLayout,
      assertion: PolicyCanvasTerminalAssertion(
        role: .source,
        endpoint: \.source,
        routePoint: { $0.points.first },
        routeSide: policyCanvasRouteSourceSide,
        label: "precomputed source"
      )
    )
    assertions.assertMarkerOffsets(
      scenario: scenario,
      markerLayout: timedRoute.output.portMarkerLayout,
      assertion: PolicyCanvasTerminalAssertion(
        role: .target,
        endpoint: \.target,
        routePoint: { $0.points.last },
        routeSide: policyCanvasRouteTargetSide,
        label: "precomputed target"
      )
    )
  }

  private static func portSpacingHotspots(
    _ report: PolicyCanvasGraphQualityReport
  ) -> String {
    let counts = Dictionary(
      grouping: report.portSpacing,
      by: { "\($0.nodeID)|\($0.side.rawValue)|\($0.kind.rawValue)" }
    )
    return
      counts
      .map { key, violations in "\(key)=\(violations.count)" }
      .sorted()
      .joined(separator: ",")
  }

  private static func semanticTerminalSideViolations(
    sampleID: String,
    edge: PolicyCanvasEdge,
    route: PolicyCanvasEdgeRoute,
    markerLayout: PolicyCanvasPortMarkerLayout
  ) -> [String] {
    [
      semanticTerminalSideViolation(
        sampleID: sampleID,
        edge: edge,
        role: .source,
        route: route,
        markerLayout: markerLayout
      ),
      semanticTerminalSideViolation(
        sampleID: sampleID,
        edge: edge,
        role: .target,
        route: route,
        markerLayout: markerLayout
      ),
    ].compactMap { $0 }
  }

  private static func semanticTerminalSideViolation(
    sampleID: String,
    edge: PolicyCanvasEdge,
    role: PolicyCanvasRouteEndpointRole,
    route: PolicyCanvasEdgeRoute,
    markerLayout: PolicyCanvasPortMarkerLayout
  ) -> String? {
    let endpoint = role == .source ? edge.source : edge.target
    let routeSide =
      role == .source ? policyCanvasRouteSourceSide(route) : policyCanvasRouteTargetSide(route)
    let expectedSide = policyCanvasResolvedPortSide(for: endpoint)
    let markerSide = markerLayout.terminal(edgeID: edge.id, role: role)?.side
    guard routeSide != expectedSide || markerSide != expectedSide else {
      return nil
    }
    return [
      "\(sampleID):\(edge.id):\(role)",
      "routeSide=\(String(describing: routeSide))",
      "markerSide=\(String(describing: markerSide))",
      "expected=\(expectedSide)",
    ].joined(separator: " ")
  }

  private static func bodyHitDetail(_ report: PolicyCanvasGraphQualityReport) -> String {
    report.bodyHits
      .map { "\($0.edgeID):\($0.obstacle.rawValue):\($0.obstacleID)" }
      .joined(separator: ",")
  }

  private static func bodyHitRouteDetail(
    _ report: PolicyCanvasGraphQualityReport,
    routes: [String: PolicyCanvasEdgeRoute]
  ) -> String {
    report.bodyHits
      .map { hit in
        let points = routes[hit.edgeID]?.points ?? []
        return "\(hit.edgeID):\(hit.obstacleID):frame=\(hit.frame):points=\(points)"
      }
      .joined(separator: ";")
  }

  private static func crossedPortDetail(_ report: PolicyCanvasGraphQualityReport) -> String {
    report.crossedPorts
      .prefix(120)
      .map { "\($0.nodeID):\($0.side.rawValue):\($0.edgeA)>\($0.edgeB)" }
      .joined(separator: ",")
  }

  private static func crossedPortRouteDetail(
    _ report: PolicyCanvasGraphQualityReport,
    routes: [String: PolicyCanvasEdgeRoute]
  ) -> String {
    report.crossedPorts
      .prefix(24)
      .map { violation in
        let pointsA = routes[violation.edgeA]?.points ?? []
        let pointsB = routes[violation.edgeB]?.points ?? []
        return [
          "\(violation.nodeID):\(violation.side.rawValue)",
          "\(violation.edgeA)=\(pointsA)",
          "\(violation.edgeB)=\(pointsB)",
        ].joined(separator: ":")
      }
      .joined(separator: ";")
  }

  private static func corridorReuseDetail(_ report: PolicyCanvasGraphQualityReport) -> String {
    report.corridors
      .filter { $0.kind == .collinear }
      .prefix(80)
      .map { violation in
        let axis = violation.isHorizontal ? "h" : "v"
        return [
          "\(violation.edgeA)~\(violation.edgeB)",
          axis,
          "\(violation.overlapStart)->\(violation.overlapEnd)",
        ].joined(separator: ":")
      }
      .joined(separator: ",")
  }

  private static func corridorReuseRouteDetail(
    _ report: PolicyCanvasGraphQualityReport,
    routes: [String: PolicyCanvasEdgeRoute]
  ) -> String {
    let routeIDs = Set(
      report.corridors.filter { $0.kind == .collinear }.flatMap {
        [$0.edgeA, $0.edgeB]
      }
    )

    return
      routes
      .filter { routeIDs.contains($0.key) }
      .sorted { $0.key < $1.key }
      .map { key, route in "\(key)=\(route.points)" }
      .joined(separator: ";")
  }

  private static func corridorParallelRouteDetail(
    _ report: PolicyCanvasGraphQualityReport,
    routes: [String: PolicyCanvasEdgeRoute]
  ) -> String {
    let routeIDs = Set(
      report.corridors.filter { $0.kind == .parallelTooClose }.prefix(40).flatMap {
        [$0.edgeA, $0.edgeB]
      }
    )

    return
      routes
      .filter { routeIDs.contains($0.key) }
      .sorted { $0.key < $1.key }
      .map { key, route in "\(key)=\(route.points)" }
      .joined(separator: ";")
  }

  private static func corridorParallelDetail(_ report: PolicyCanvasGraphQualityReport) -> String {
    report.corridors
      .filter { $0.kind == .parallelTooClose }
      .prefix(80)
      .map { violation in
        let axis = violation.isHorizontal ? "h" : "v"
        return [
          "\(violation.edgeA)~\(violation.edgeB)",
          axis,
          String(format: "sep=%.3f", violation.separation),
          "\(violation.overlapStart)->\(violation.overlapEnd)",
        ].joined(separator: ":")
      }
      .joined(separator: ",")
  }

  private static func routeSegmentDetail(_ report: PolicyCanvasGraphQualityReport) -> String {
    report.routeSegments
      .prefix(80)
      .map { violation in
        [
          violation.edgeID,
          violation.kind.rawValue,
          String(format: "len=%.3f", violation.length),
          "\(violation.start)->\(violation.end)",
        ].joined(separator: ":")
      }
      .joined(separator: ",")
  }

  private static func portSpacingDetail(
    _ report: PolicyCanvasGraphQualityReport,
    matching nodeID: String
  ) -> String {
    report.portSpacing
      .filter { $0.nodeID == nodeID }
      .map {
        [
          $0.kind.rawValue,
          $0.side.rawValue,
          String(format: "%.1f", $0.gap),
          $0.edgeIDs.joined(separator: "+"),
        ].joined(separator: ":")
      }
      .joined(separator: ",")
  }

  private static func elkEndpointSides(
    _ edges: [PolicyCanvasEdge],
    edgePrefix: String
  ) -> String {
    edges
      .filter { $0.id.hasPrefix(edgePrefix) }
      .sorted { $0.id < $1.id }
      .map {
        "\($0.id)=source:\(PolicyCanvasPortSide.trailing.rawValue),target:\(PolicyCanvasPortSide.leading.rawValue)"
      }
      .joined(separator: ",")
  }

  private static func routeDetail(
    _ routes: [String: PolicyCanvasEdgeRoute],
    edgePrefix: String
  ) -> String {
    routes
      .filter { $0.key.hasPrefix(edgePrefix) }
      .sorted { $0.key < $1.key }
      .map { key, route in "\(key)=\(route.points)" }
      .joined(separator: ";")
  }

  private static func precomputedAttachFailure(
    result: PolicyCanvasLayoutResult,
    nodes: [PolicyCanvasNode],
    edges: [PolicyCanvasEdge]
  ) -> String {
    guard let precomputedRoutes = result.precomputedRoutes else {
      return "missing-precomputed-routes"
    }
    let edgeIDs = Set(edges.map(\.id))
    guard precomputedRoutes.routes.count == edgeIDs.count,
      Set(precomputedRoutes.routes.keys) == edgeIDs
    else {
      return "route-count=\(precomputedRoutes.routes.count) edge-count=\(edgeIDs.count)"
    }
    let nodePositions = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.position) })
    let offsetRoutes: PolicyCanvasPrecomputedRouteSet
    if let nodeID = result.nodePositions.keys.sorted().first,
      let resultPosition = result.nodePositions[nodeID],
      let appliedPosition = nodePositions[nodeID]
    {
      offsetRoutes = precomputedRoutes.offsetBy(
        dx: appliedPosition.x - resultPosition.x,
        dy: appliedPosition.y - resultPosition.y
      )
    } else {
      offsetRoutes = precomputedRoutes
    }
    let nodeFrames = Dictionary(
      uniqueKeysWithValues: nodes.map {
        ($0.id, CGRect(origin: $0.position, size: PolicyCanvasLayout.nodeSize))
      }
    )
    for edge in edges.sorted(by: { $0.id < $1.id }) {
      guard let route = offsetRoutes.routes[edge.id] else {
        return "\(edge.id):missing-route"
      }
      guard let first = route.points.first,
        let last = route.points.last,
        let sourceFrame = nodeFrames[edge.source.nodeID],
        let targetFrame = nodeFrames[edge.target.nodeID]
      else {
        return "\(edge.id):missing-terminal"
      }
      if !precomputedRouteTerminalAttaches(first, to: sourceFrame) {
        return "\(edge.id):source point=\(first) frame=\(sourceFrame)"
      }
      if !precomputedRouteTerminalAttaches(last, to: targetFrame) {
        return "\(edge.id):target point=\(last) frame=\(targetFrame)"
      }
    }
    return "none"
  }

  private static func precomputedRouteTerminalAttaches(
    _ point: CGPoint,
    to frame: CGRect
  ) -> Bool {
    let tolerance = PolicyCanvasLayout.portDiameter + 4
    let withinVertical = point.y >= frame.minY - tolerance && point.y <= frame.maxY + tolerance
    let withinHorizontal = point.x >= frame.minX - tolerance && point.x <= frame.maxX + tolerance
    let onLeading = withinVertical && abs(point.x - frame.minX) <= tolerance
    let onTrailing = withinVertical && abs(point.x - frame.maxX) <= tolerance
    let onTop = withinHorizontal && abs(point.y - frame.minY) <= tolerance
    let onBottom = withinHorizontal && abs(point.y - frame.maxY) <= tolerance
    return onLeading || onTrailing || onTop || onBottom
  }

  @Test func dumpExtremeGalaxyModule10Routes() async throws {
    let sample = try #require(PolicyCanvasLabSamples.sample(id: "extreme-galaxy"))
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: sample.document, simulation: nil, audit: nil)
    viewModel.reflowLayout(preserveManualAnchors: false, force: true)
    let input = PolicyCanvasRouteWorkerInput(
      nodes: viewModel.nodes,
      groups: viewModel.groups,
      edges: viewModel.edges,
      fontScale: 1,
      routingHints: viewModel.routingHints,
      precomputedRoutes: viewModel.precomputedRoutes,
      algorithmSelection: .referenceRouting
    )
    let output = await PolicyCanvasRouteWorker().compute(input: input)
    let nodeIDs = [
      "xg-m10-action-gate",
      "xg-m10-evidence",
      "xg-m10-ifelse",
      "xg-m10-switch",
      "xg-m10-hub",
      "xg-m10-risk",
      "xg-m10-human",
      "xg-m10-consensus",
      "xg-m10-dry-run",
      "xg-m10-handoff",
    ]
    let edgeIDs = [
      "xge:m10-gate-evidence",
      "xge:m10-gate-switch",
      "xge:m10-gate-dry",
      "xge:m10-gate-hub",
      "xge:m10-gate-human",
      "xge:m10-gate-handoff",
      "xge:m10-switch-wait",
      "xge:m10-switch-human",
      "xge:m10-switch-deny",
      "xge:m10-switch-event",
      "xge:m10-switch-risk",
    ]
    var lines: [String] = []
    lines.append("precomputedRoutes: \(viewModel.precomputedRoutes?.routes.count ?? -1)")
    for nodeID in nodeIDs {
      guard let node = viewModel.nodes.first(where: { $0.id == nodeID }) else {
        continue
      }
      lines.append(
        "node \(nodeID) frame=\(CGRect(origin: node.position, size: PolicyCanvasLayout.nodeSize))"
      )
    }
    for edgeID in edgeIDs {
      guard let route = output.routes[edgeID] else {
        lines.append("edge \(edgeID) missing")
        continue
      }
      lines.append("edge \(edgeID) points=\(route.points)")
    }
    writeReport(lines.joined(separator: "\n"), name: "extreme-galaxy-module10-routes.txt")
    #expect(output.routes.count == viewModel.edges.count)
  }

  /// Every lab and shipping-canvas render goes through `policyCanvasAtomicReflow`
  /// `RoutePlan`. Its port markers must land where the canvas draws them: on the
  /// wire end and inside the node body. The canvas positions every dot at the
  /// declaration-order anchor (`portY(declarationIndex) + axisOffset`), so the
  /// route computation has to measure that offset from the declaration anchor too.
  /// Measuring it from the crossing-minimal optimized anchor instead desyncs the
  /// dot by `(declarationIndex - optimizedIndex) * spacing`, which on a reordered
  /// gate node pushes ports above or below the card and off their wires - the
  /// extreme-galaxy regression where gate outputs rendered outside the node when a
  /// separate large-graph route path diverged from the main one. Drives the real
  /// reflow-route plan against every sample, including the largest, so a divergent
  /// or size-gated path can never reintroduce the bug.
  @Test func reflowRoutePlanKeepsPortMarkersOnWiresInsideNodes() async throws {
    var exercised: [String] = []
    var offenders: [String] = []
    for sample in PolicyCanvasLabSamples.all {
      let viewModel = PolicyCanvasViewModel.sample()
      viewModel.load(document: sample.document, simulation: nil, audit: nil)
      guard
        let plan = await policyCanvasAtomicReflowRoutePlan(
          viewModel: viewModel,
          preserveManualAnchors: false,
          force: true,
          fontScale: 1,
          routeWorker: PolicyCanvasRouteWorker(),
          routesCurrentGraphWhenUnchanged: true
        )
      else {
        continue
      }
      exercised.append(sample.id)
      let nodes = plan.graph.nodes
      let nodesByID = Self.nodesByID(nodes)
      let nodeSizes = PolicyCanvasLayout.nodeSizes(for: nodes, edges: plan.graph.edges)
      for edge in plan.graph.edges {
        for (role, endpoint, point) in [
          (
            PolicyCanvasRouteEndpointRole.source, edge.source,
            plan.output.routes[edge.id]?.points.first
          ),
          (
            PolicyCanvasRouteEndpointRole.target, edge.target,
            plan.output.routes[edge.id]?.points.last
          ),
        ] {
          guard
            let point,
            let terminal = plan.output.portMarkerLayout.terminal(edgeID: edge.id, role: role),
            let node = nodesByID[endpoint.nodeID],
            let center = policyCanvasPortMarkerCenter(
              endpoint: endpoint, terminal: terminal,
              nodesByID: nodesByID, nodeSizes: nodeSizes)
          else {
            continue
          }
          let frame = CGRect(
            origin: node.position,
            size: nodeSizes[node.id] ?? PolicyCanvasLayout.nodeSize(for: node))
          if center.y < frame.minY || center.y > frame.maxY
            || center.x < frame.minX || center.x > frame.maxX
          {
            offenders.append(
              "\(sample.id):\(edge.id):\(role):\(terminal.side.rawValue):outside center=\(center) frame=\(frame)")
          }
          let gap = hypot(point.x - center.x, point.y - center.y)
          if gap > 0.5 {
            offenders.append(
              "\(sample.id):\(edge.id):\(role):\(terminal.side.rawValue):offwire gap=\(gap)")
          }
        }
      }
    }
    #expect(
      exercised.contains("extreme-galaxy"),
      "the largest sample must exercise the reflow route plan; got \(exercised)"
    )
    #expect(
      offenders.isEmpty,
      "reflow-route-plan port markers must stay on their wires inside their nodes: \(offenders.count) - \(offenders.prefix(20))"
    )
  }

  /// Every crossed-port the measure flags on a real lab sample must be a genuine
  /// crossing: the two wires' routes must actually intersect between their ports.
  /// Guards against the order-key regression where wires funnelling through a
  /// shared fan-in channel were flagged as crossed even though they ran parallel.
  @Test func crossedPortsFlagOnlyRealCrossings() async throws {
    for sample in PolicyCanvasLabSamples.all {
      let routed = try await routedSample(sampleID: sample.id)
      for violation in routed.report.crossedPorts {
        let aPoints = routed.routes[violation.edgeA]?.points ?? []
        let bPoints = routed.routes[violation.edgeB]?.points ?? []
        // A flagged pair is real if the routes properly intersect, OR if they
        // funnel through one shared collinear channel - the swap case the
        // intersection test cannot see. Wires in separate lanes (the order-key
        // regression) satisfy neither, so this still guards against it.
        let crosses =
          !policyCanvasBruteForceCrossings(aPoints, bPoints).isEmpty
          || policyCanvasSharesCollinearChannel(aPoints, bPoints)
        #expect(
          crosses,
          "\(sample.id): \(violation.edgeA) x \(violation.edgeB) flagged crossed but routes neither meet nor share a channel"
        )
      }
    }
  }

  /// True when two polylines properly intersect at an interior point more than a
  /// port diameter from either polyline's own endpoints - the same geometric test
  /// the measure uses, run independently here to confirm its verdicts.
  private func policyCanvasBruteForceCrossings(
    _ a: [CGPoint],
    _ b: [CGPoint]
  ) -> [CGPoint] {
    guard a.count >= 2, b.count >= 2 else { return [] }
    var hits: [CGPoint] = []
    let endpoints = [a.first, a.last, b.first, b.last].compactMap { $0 }
    for indexA in 1..<a.count {
      for indexB in 1..<b.count {
        guard
          let point = policyCanvasSegmentIntersection(
            a[indexA - 1],
            a[indexA],
            b[indexB - 1],
            b[indexB]
          )
        else { continue }
        if endpoints.contains(where: {
          hypot($0.x - point.x, $0.y - point.y) < PolicyCanvasLayout.portDiameter
        }) {
          continue
        }
        hits.append(point)
      }
    }
    return hits
  }

  /// True when the two polylines have a pair of collinear segments (same vertical
  /// or horizontal line) whose extents overlap by more than a port diameter - the
  /// shared channel two wires funnel through. Independent of the measure's own
  /// channel test; together with the proper-intersection check it confirms a
  /// flagged crossing is grounded in real geometry, not an order-key guess.
  private func policyCanvasSharesCollinearChannel(_ a: [CGPoint], _ b: [CGPoint]) -> Bool {
    guard a.count >= 2, b.count >= 2 else { return false }
    for indexA in 1..<a.count {
      for indexB in 1..<b.count {
        let (a1, a2, b1, b2) = (a[indexA - 1], a[indexA], b[indexB - 1], b[indexB])
        let aVertical = abs(a1.x - a2.x) <= 0.5
        let bVertical = abs(b1.x - b2.x) <= 0.5
        let aHorizontal = abs(a1.y - a2.y) <= 0.5
        let bHorizontal = abs(b1.y - b2.y) <= 0.5
        if aVertical, bVertical, abs(a1.x - b1.x) <= 0.5,
          policyCanvasOverlap(a1.y, a2.y, b1.y, b2.y)
            > PolicyCanvasLayout.portDiameter
        {
          return true
        }
        if aHorizontal, bHorizontal, abs(a1.y - b1.y) <= 0.5,
          policyCanvasOverlap(a1.x, a2.x, b1.x, b2.x)
            > PolicyCanvasLayout.portDiameter
        {
          return true
        }
      }
    }
    return false
  }

  private func policyCanvasOverlap(_ a1: CGFloat, _ a2: CGFloat, _ b1: CGFloat, _ b2: CGFloat)
    -> CGFloat
  {
    min(max(a1, a2), max(b1, b2)) - max(min(a1, a2), min(b1, b2))
  }

  /// Proper interior intersection of two segments, or nil if they miss, only
  /// touch at an endpoint, or are collinear.
  private func policyCanvasSegmentIntersection(
    _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ p4: CGPoint
  ) -> CGPoint? {
    let denominator = (p2.x - p1.x) * (p4.y - p3.y) - (p2.y - p1.y) * (p4.x - p3.x)
    guard abs(denominator) > 0.0001 else { return nil }
    let t = ((p3.x - p1.x) * (p4.y - p3.y) - (p3.y - p1.y) * (p4.x - p3.x)) / denominator
    let u = ((p3.x - p1.x) * (p2.y - p1.y) - (p3.y - p1.y) * (p2.x - p1.x)) / denominator
    guard t > 0.0001, t < 0.9999, u > 0.0001, u < 0.9999 else { return nil }
    return CGPoint(x: p1.x + t * (p2.x - p1.x), y: p1.y + t * (p2.y - p1.y))
  }

  private func measuredRouteComputation(
    input: PolicyCanvasRouteWorkerInput
  ) -> TimedRouteComputation {
    let routeStart = Date()
    let prepareStart = Date()
    let prepared = PolicyCanvasPreparedRouteInput(input: input)
    let prepareMs = Date().timeIntervalSince(prepareStart) * 1_000

    if input.precomputedRoutes != nil {
      let computation = prepared.routeComputation(
        router: policyCanvasDefaultEdgeRouter(),
        algorithmSelection: input.algorithmSelection
      )
      return TimedRouteComputation(
        output: computation,
        routeMs: Date().timeIntervalSince(routeStart) * 1_000,
        prepareMs: prepareMs,
        passContextMs: 0,
        routeSelectionMs: 0,
        markerPlacementMs: 0,
        postProcessMs: 0,
        terminalsMs: 0,
        labelsMs: 0,
        boundsMs: 0,
        portVisibilityMs: 0,
        selectionPasses: 0,
        fastPath: true
      )
    }

    let algorithms = PolicyCanvasAlgorithmRegistry.routingAlgorithms(for: input.algorithmSelection)
    let defaultRouter = policyCanvasDefaultEdgeRouter()
    let selectedRouter: any PolicyCanvasEdgeRouter =
      input.algorithmSelection.algorithmID(for: .edgeRouting)
        == PolicyCanvasAlgorithmDefaults.paddedOrthogonalVisibilityAStar
      ? defaultRouter
      : algorithms.edgeRouter
    let nodeIndex = prepared.nodeIndex

    let passContextStart = Date()
    let passContext = prepared.displayedRoutePassContext(nodeIndex: nodeIndex)
    let passContextMs = Date().timeIntervalSince(passContextStart) * 1_000

    var routeSelectionMs = 0.0
    var markerPlacementMs = 0.0
    var selectionPasses = 0

    func selectedRoutes(
      portMarkerLayout: PolicyCanvasPortMarkerLayout?
    ) -> [String: PolicyCanvasEdgeRoute] {
      let start = Date()
      defer {
        routeSelectionMs += Date().timeIntervalSince(start) * 1_000
        selectionPasses += 1
      }
      return algorithms.routeSelection.selectRoutes(
        input: PolicyCanvasRouteSelectionInput(
          prepared: prepared,
          router: selectedRouter,
          portMarkerLayout: portMarkerLayout,
          passContext: passContext
        )
      )
    }

    func placedMarkers(
      routes: [String: PolicyCanvasEdgeRoute]
    ) -> PolicyCanvasPortMarkerLayout {
      let start = Date()
      defer {
        markerPlacementMs += Date().timeIntervalSince(start) * 1_000
      }
      return algorithms.portMarkerPlacement.placeMarkers(
        input: PolicyCanvasPortMarkerPlacementInput(
          prepared: prepared,
          routes: routes,
          nodeIndex: nodeIndex
        )
      )
    }

    let initialSeed = algorithms.portMarkerPlacement.seedMarkers(
      input: PolicyCanvasPortMarkerSeedInput(prepared: prepared, nodeIndex: nodeIndex)
    )
    var routes: [String: PolicyCanvasEdgeRoute]
    var portMarkerLayout: PolicyCanvasPortMarkerLayout
    if let initialSeed {
      routes = selectedRoutes(portMarkerLayout: initialSeed)
      portMarkerLayout = placedMarkers(routes: routes)
      if prepared.edges.count <= 1_000, portMarkerLayout != initialSeed {
        var seenLayouts = [initialSeed, portMarkerLayout]
        var converged = false
        for _ in 0..<3 {
          let nextRoutes = selectedRoutes(portMarkerLayout: portMarkerLayout)
          let nextLayout = placedMarkers(routes: nextRoutes)
          if nextLayout == portMarkerLayout {
            routes = nextRoutes
            portMarkerLayout = nextLayout
            converged = true
            break
          }
          if seenLayouts.contains(nextLayout) {
            routes = selectedRoutes(portMarkerLayout: nextLayout)
            portMarkerLayout = nextLayout
            converged = true
            break
          }
          seenLayouts.append(nextLayout)
          routes = nextRoutes
          portMarkerLayout = nextLayout
        }
        if !converged {
          routes = selectedRoutes(portMarkerLayout: portMarkerLayout)
        }
      }
    } else {
      routes = selectedRoutes(portMarkerLayout: nil)
      portMarkerLayout = placedMarkers(routes: routes)
      var seenLayouts = [portMarkerLayout]
      var converged = false
      for _ in 0..<3 {
        let nextRoutes = selectedRoutes(portMarkerLayout: portMarkerLayout)
        let nextLayout = placedMarkers(routes: nextRoutes)
        if nextLayout == portMarkerLayout {
          routes = nextRoutes
          portMarkerLayout = nextLayout
          converged = true
          break
        }
        if seenLayouts.contains(nextLayout) {
          routes = selectedRoutes(portMarkerLayout: nextLayout)
          portMarkerLayout = nextLayout
          converged = true
          break
        }
        seenLayouts.append(nextLayout)
        routes = nextRoutes
        portMarkerLayout = nextLayout
      }
      if !converged {
        routes = selectedRoutes(portMarkerLayout: portMarkerLayout)
      }
    }

    let postProcessStart = Date()
    let processedRoutes = algorithms.routePostProcessing.processRoutes(
      input: PolicyCanvasRoutePostProcessingInput(prepared: prepared, routes: routes)
    )
    let postProcessMs = Date().timeIntervalSince(postProcessStart) * 1_000

    let terminalsStart = Date()
    let finalRoutes = policyCanvasRoutesPreservingRouteTerminals(
      original: routes,
      processed: processedRoutes
    )
    let terminalsMs = Date().timeIntervalSince(terminalsStart) * 1_000

    let labelsStart = Date()
    let labelPositions = algorithms.labelPlacement.placeLabels(
      input: PolicyCanvasLabelPlacementInput(prepared: prepared, routes: finalRoutes)
    )
    let labelsMs = Date().timeIntervalSince(labelsStart) * 1_000

    let boundsStart = Date()
    let visibleBounds = prepared.visibleBounds(
      routes: finalRoutes,
      labelPositions: labelPositions
    )
    let boundsMs = Date().timeIntervalSince(boundsStart) * 1_000

    let portVisibilityStart = Date()
    let portVisibility = prepared.portVisibility(routes: finalRoutes, nodeIndex: nodeIndex)
    let portVisibilityMs = Date().timeIntervalSince(portVisibilityStart) * 1_000

    return TimedRouteComputation(
      output: PolicyCanvasPreparedRouteComputation(
        routes: finalRoutes,
        labelPositions: labelPositions,
        portVisibility: portVisibility,
        portMarkerLayout: portMarkerLayout,
        visibleBounds: visibleBounds
      ),
      routeMs: Date().timeIntervalSince(routeStart) * 1_000,
      prepareMs: prepareMs,
      passContextMs: passContextMs,
      routeSelectionMs: routeSelectionMs,
      markerPlacementMs: markerPlacementMs,
      postProcessMs: postProcessMs,
      terminalsMs: terminalsMs,
      labelsMs: labelsMs,
      boundsMs: boundsMs,
      portVisibilityMs: portVisibilityMs,
      selectionPasses: selectionPasses,
      fastPath: false
    )
  }

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

  private func elkBenchmarkGraphJSON(
    nodes: [PolicyCanvasNode],
    edges: [PolicyCanvasEdge],
    includesPorts: Bool = false
  ) throws -> String {
    let portModel = includesPorts ? elkEndpointPorts(edges: edges) : nil
    let children: [[String: Any]] = nodes.sorted { $0.id < $1.id }.map { node in
      var child: [String: Any] = [
        "id": node.id,
        "width": Double(PolicyCanvasLayout.nodeSize.width),
        "height": Double(PolicyCanvasLayout.nodeSize.height),
      ]
      if let ports = portModel?.portsByNode[node.id], !ports.isEmpty {
        child["layoutOptions"] = ["org.eclipse.elk.portConstraints": "FIXED_POS"]
        child["ports"] = ports
      }
      return child
    }
    let labelMetrics = PolicyCanvasEdgeLabelMetrics(fontScale: 1)
    let elkEdges: [[String: Any]] = edges.sorted { $0.id < $1.id }.map { edge in
      var elkEdge: [String: Any] = [
        "id": edge.id,
        "sources": [portModel?.sourcePortByEdge[edge.id] ?? edge.source.nodeID],
        "targets": [portModel?.targetPortByEdge[edge.id] ?? edge.target.nodeID],
      ]
      if !edge.label.isEmpty {
        let size = labelMetrics.size(for: edge.label)
        elkEdge["labels"] = [
          [
            "id": "\(edge.id)__label",
            "text": edge.label,
            "width": Double(size.width),
            "height": Double(size.height),
          ]
        ]
      }
      return elkEdge
    }
    let graph: [String: Any] = [
      "id": "extreme-galaxy",
      "layoutOptions": [
        "elk.algorithm": "layered",
        "elk.direction": "RIGHT",
        "elk.edgeRouting": "ORTHOGONAL",
        "elk.spacing.nodeNode": "80",
        "elk.spacing.edgeEdge": "\(Int(PolicyCanvasLayout.defaultEdgeLineSpacing.rounded()))",
        "elk.spacing.edgeNode": "40",
        "elk.layered.spacing.nodeNodeBetweenLayers": "120",
      ],
      "children": children,
      "edges": elkEdges,
    ]
    let data = try JSONSerialization.data(withJSONObject: graph, options: [.prettyPrinted])
    return String(decoding: data, as: UTF8.self)
  }

  private struct ELKEndpointPortModel {
    var portsByNode: [String: [[String: Any]]]
    var sourcePortByEdge: [String: String]
    var targetPortByEdge: [String: String]
  }

  private func elkEndpointPorts(edges: [PolicyCanvasEdge]) -> ELKEndpointPortModel {
    var portsByNode: [String: [[String: Any]]] = [:]
    var sourcePortByEdge: [String: String] = [:]
    var targetPortByEdge: [String: String] = [:]

    struct PartialPort {
      let id: String
      let edgeID: String
      let roleRank: Int
      let nodeID: String
      let side: PolicyCanvasPortSide
    }

    var partials: [PartialPort] = []
    partials.reserveCapacity(edges.count * 2)
    for edge in edges.sorted(by: { $0.id < $1.id }) {
      let sourceID = "\(edge.id)__source"
      let targetID = "\(edge.id)__target"
      sourcePortByEdge[edge.id] = sourceID
      targetPortByEdge[edge.id] = targetID
      partials.append(
        PartialPort(
          id: sourceID,
          edgeID: edge.id,
          roleRank: 0,
          nodeID: edge.source.nodeID,
          side: .trailing
        )
      )
      partials.append(
        PartialPort(
          id: targetID,
          edgeID: edge.id,
          roleRank: 1,
          nodeID: edge.target.nodeID,
          side: .leading
        )
      )
    }

    let groups = Dictionary(grouping: partials) { "\($0.nodeID)|\($0.side.rawValue)" }
    for key in groups.keys.sorted() {
      let values = groups[key, default: []].sorted {
        if $0.edgeID == $1.edgeID {
          return $0.roleRank < $1.roleRank
        }
        return $0.edgeID < $1.edgeID
      }
      guard let side = values.first?.side else {
        continue
      }
      let coordinates = policyCanvasPortMarkerCoordinates(
        count: values.count,
        base: policyCanvasSideExtent(side: side) / 2,
        spacing: policyCanvasMinimumPortMarkerSpacing(),
        extent: policyCanvasSideExtent(side: side),
        inset: policyCanvasPortMarkerInset()
      )
      let sideName = elkPortSideName(side)
      for (index, value) in values.enumerated() {
        let origin = elkPortOrigin(side: value.side, coordinate: coordinates[index])
        portsByNode[value.nodeID, default: []].append([
          "id": value.id,
          "width": Double(PolicyCanvasLayout.portDiameter),
          "height": Double(PolicyCanvasLayout.portDiameter),
          "x": Double(origin.x),
          "y": Double(origin.y),
          "layoutOptions": [
            "org.eclipse.elk.port.side": sideName,
            "org.eclipse.elk.port.index": index,
          ],
        ])
      }
    }
    return ELKEndpointPortModel(
      portsByNode: portsByNode,
      sourcePortByEdge: sourcePortByEdge,
      targetPortByEdge: targetPortByEdge
    )
  }

  private func elkPortOrigin(
    side: PolicyCanvasPortSide,
    coordinate: CGFloat
  ) -> CGPoint {
    let radius = PolicyCanvasLayout.portDiameter / 2
    switch side {
    case .leading:
      return CGPoint(x: 0, y: coordinate - radius)
    case .trailing:
      return CGPoint(x: PolicyCanvasLayout.nodeSize.width - radius, y: coordinate - radius)
    case .top:
      return CGPoint(x: coordinate - radius, y: -radius)
    case .bottom:
      return CGPoint(x: coordinate - radius, y: PolicyCanvasLayout.nodeSize.height - radius)
    }
  }

  private func elkPortSideName(_ side: PolicyCanvasPortSide) -> String {
    switch side {
    case .leading:
      "WEST"
    case .trailing:
      "EAST"
    case .top:
      "NORTH"
    case .bottom:
      "SOUTH"
    }
  }
}
