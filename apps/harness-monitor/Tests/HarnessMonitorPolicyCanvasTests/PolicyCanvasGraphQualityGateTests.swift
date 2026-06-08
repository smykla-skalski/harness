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

  /// Route a lab sample exactly the way the lab renders it (load -> reflow ->
  /// route worker) and measure the resulting graph.
  func routedReport(sampleID: String) async throws -> PolicyCanvasGraphQualityReport {
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
    return policyCanvasMeasureGraphQuality(
      nodes: viewModel.nodes,
      groups: viewModel.groups,
      edges: viewModel.edges,
      routes: output.routes
    )
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
    #expect(budgetedSampleIDs == allSampleIDs.filter {
      !Self.debugOnlyStressSampleIDs.contains($0)
    })
    #expect(budgetedSampleIDs.contains("extreme"))
    #expect(budgetedSampleIDs.contains("extreme-braid"))
    #expect(!budgetedSampleIDs.contains("extreme-matrix"))
    #expect(!budgetedSampleIDs.contains("extreme-galaxy"))
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
      edges: componentGraph.mappedEdges,
      algorithmSelection: .referenceRouting
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
      mode: .explicitReflow(preserveManualAnchors: false),
      algorithmSelection: viewModel.algorithmSelection
    )
    let elkProbeMs = Date().timeIntervalSince(elkProbeStart) * 1_000
    var elkProbeAppliedRoutes = -1
    var elkProbeOverlapCleanup = false
    var elkProbeSingleFedAlignment = false
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
        nodes: probeNodes
      )
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
      routes: timedRoute.output.routes
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
      "label_overlaps: \(report.count(for: .labelOverlaps))",
      "corridor_parallel: \(report.count(for: .corridorParallel))",
      "corridor_reuse: \(report.count(for: .corridorReuse))",
    ].joined(separator: "\n")
    writeReport(contents, name: "extreme-galaxy-performance.txt")
    #expect(timedRoute.output.routes.count == viewModel.edges.count)
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
        "height": Double(PolicyCanvasLayout.nodeSize.height)
      ]
      if let ports = portModel?.portsByNode[node.id], !ports.isEmpty {
        child["layoutOptions"] = ["elk.portConstraints": "FIXED_SIDE"]
        child["ports"] = ports
      }
      return child
    }
    let labelMetrics = PolicyCanvasEdgeLabelMetrics(fontScale: 1)
    let elkEdges: [[String: Any]] = edges.sorted { $0.id < $1.id }.map { edge in
      var elkEdge: [String: Any] = [
        "id": edge.id,
        "sources": [portModel?.sourcePortByEdge[edge.id] ?? edge.source.nodeID],
        "targets": [portModel?.targetPortByEdge[edge.id] ?? edge.target.nodeID]
      ]
      if !edge.label.isEmpty {
        let size = labelMetrics.size(for: edge.label)
        elkEdge["labels"] = [
          [
            "id": "\(edge.id)__label",
            "text": edge.label,
            "width": Double(size.width),
            "height": Double(size.height)
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
        "elk.spacing.edgeEdge": "38",
        "elk.spacing.edgeNode": "40",
        "elk.layered.spacing.nodeNodeBetweenLayers": "120"
      ],
      "children": children,
      "edges": elkEdges
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
    var sideCounts: [String: Int] = [:]

    func appendPort(
      id: String,
      nodeID: String,
      side: PolicyCanvasPortSide
    ) {
      let sideName = elkPortSideName(side)
      let countKey = "\(nodeID)|\(sideName)"
      let index = sideCounts[countKey, default: 0]
      sideCounts[countKey] = index + 1
      portsByNode[nodeID, default: []].append([
        "id": id,
        "width": Double(PolicyCanvasLayout.portDiameter),
        "height": Double(PolicyCanvasLayout.portDiameter),
        "layoutOptions": [
          "elk.port.side": sideName,
          "elk.port.index": index
        ]
      ])
    }

    for edge in edges.sorted(by: { $0.id < $1.id }) {
      let sourceID = "\(edge.id)__source"
      let targetID = "\(edge.id)__target"
      sourcePortByEdge[edge.id] = sourceID
      targetPortByEdge[edge.id] = targetID
      appendPort(
        id: sourceID,
        nodeID: edge.source.nodeID,
        side: edge.source.side ?? .trailing
      )
      appendPort(
        id: targetID,
        nodeID: edge.target.nodeID,
        side: edge.target.side ?? .leading
      )
    }
    return ELKEndpointPortModel(
      portsByNode: portsByNode,
      sourcePortByEdge: sourcePortByEdge,
      targetPortByEdge: targetPortByEdge
    )
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
