import CoreGraphics
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

/// The live drag display routes the moved node's incident edges through the
/// selective recompute every gesture tick. The user saw a wire sliced through a
/// node body while dragging the "supervisor:branch-protection-blocked" terminal
/// of the Default policy across open space - the selective pass froze a
/// non-incident edge the moved body landed on, so the drag showed a crossing the
/// drop would clear. Selective reroute is only correct if the displayed drag
/// output never crosses a body that a full reconverge of the same positions
/// avoids. This sweeps the terminal across the whole canvas and replicates the
/// viewport body's exact display decision at every landing spot to guard that.
@MainActor
struct PolicyCanvasSelectiveDragBodyHitTests {
  private func loadedDefault() -> PolicyCanvasViewModel {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(
      document: PolicyCanvasLabSamples.realDefault, simulation: nil, audit: nil
    )
    viewModel.reflowLayout(preserveManualAnchors: false, force: true)
    return viewModel
  }

  private func input(
    nodes: [PolicyCanvasNode], viewModel: PolicyCanvasViewModel
  ) -> PolicyCanvasRouteWorkerInput {
    PolicyCanvasRouteWorkerInput(
      nodes: nodes,
      groups: viewModel.groups,
      edges: viewModel.edges,
      fontScale: 1,
      routingHints: nil,
      precomputedRoutes: nil,
      algorithmSelection: .referenceRouting
    )
  }

  private func bodyHitKeys(
    _ output: PolicyCanvasRouteWorkerOutput,
    nodes: [PolicyCanvasNode],
    viewModel: PolicyCanvasViewModel
  ) -> Set<String> {
    let report = policyCanvasMeasureGraphQuality(
      nodes: nodes,
      groups: viewModel.groups,
      edges: viewModel.edges,
      routes: output.routes,
      labelPositions: output.labelPositions,
      portMarkerLayout: output.portMarkerLayout
    )
    var keys: Set<String> = []
    for hit in report.bodyHits {
      keys.insert(hit.edgeID + " -> " + hit.obstacleID)
    }
    return keys
  }

  /// Replicate the viewport body's drag-display decision exactly: compute the
  /// translate projection, and when it can commit, prefer the live selective
  /// route, else fall back to the projection - then measure body hits on the
  /// output that actually reaches the canvas. Sweeping the dragged terminal
  /// across a grid spanning the whole canvas finds any landing spot where the
  /// displayed wire crosses a body the full reroute would route clear.
  @Test("no drag position makes the displayed output cross a body the full reroute avoids")
  func displayedDragOutputNeverCrossesABody() async throws {
    let viewModel = loadedDefault()
    let movedID = "supervisor:merge-deny:branch-protection"
    guard let movedIndex = viewModel.nodes.firstIndex(where: { $0.id == movedID }) else {
      Issue.record("branch-protection terminal not found in Default sample")
      return
    }
    let baseline = await PolicyCanvasRouteWorker().compute(
      input: input(nodes: viewModel.nodes, viewModel: viewModel)
    )
    let baselinePositions = policyCanvasNodePositionsByID(viewModel.nodes)

    let xs = viewModel.nodes.map(\.position.x)
    let ys = viewModel.nodes.map(\.position.y)
    let minX = (xs.min() ?? 1100) - 120
    let maxX = (xs.max() ?? 3100) + 120
    let minY = (ys.min() ?? 1100) - 200
    let maxY = (ys.max() ?? 1900) + 200

    var failures: [String] = []
    var x = minX
    while x <= maxX {
      var y = minY
      while y <= maxY {
        var moved = viewModel.nodes
        moved[movedIndex].position = CGPoint(x: x, y: y)

        let projection = policyCanvasProjectedRouteResult(
          input: PolicyCanvasProjectedRouteInput(
            cachedOutput: baseline,
            cachedNodePositionsByID: baselinePositions,
            currentNodes: moved,
            groups: viewModel.groups,
            edges: viewModel.edges,
            fontScale: 1
          )
        )
        let live =
          projection.canCommitAsCurrentGraph
          ? policyCanvasLiveDragRoutedOutput(
            nodes: moved,
            groups: viewModel.groups,
            edges: viewModel.edges,
            fontScale: 1,
            algorithmSelection: viewModel.algorithmSelection,
            movedNodeIDs: [movedID],
            previous: baseline
          )
          : nil
        let displayed = live ?? projection.output

        let full = await PolicyCanvasRouteWorker().compute(
          input: input(nodes: moved, viewModel: viewModel)
        )
        let fullHits = bodyHitKeys(full, nodes: moved, viewModel: viewModel)
        let displayedHits = bodyHitKeys(displayed, nodes: moved, viewModel: viewModel)
        let extra = displayedHits.subtracting(fullHits).sorted()
        if !extra.isEmpty {
          let source = live != nil ? "selective" : "translate"
          failures.append("pos \(Int(x)),\(Int(y)) [\(source)]: " + extra.joined(separator: ", "))
        }
        y += 120
      }
      x += 120
    }

    let message = "\(failures.count) crossing positions:\n" + failures.prefix(40).joined(separator: "\n")
    #expect(failures.isEmpty, Comment(rawValue: message))
  }
}
