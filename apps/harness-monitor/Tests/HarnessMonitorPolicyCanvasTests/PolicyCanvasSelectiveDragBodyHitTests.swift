import CoreGraphics
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

/// The user saw a wire sliced through the "supervisor:branch-protection-blocked"
/// node body, and it persisted after the drop. The crossing is NOT a drag-path
/// defect: the full committed route (`routeComputation`) itself leaves a
/// non-incident wire through the moved body when the node is dropped onto an
/// open-lane wire, because the converged path had no body-hit repair and the
/// visibility A* (with alternate-side retries) cannot always find the clear
/// orthogonal path that exists. Body-hit repair now runs in the full path with a
/// guaranteed go-around escalation. These tests sweep the terminal across the
/// whole canvas, replicate the viewport body's exact display decision at every
/// landing spot, and assert the displayed AND the dropped output never cross the
/// moved body where there is wire-lane clearance to route around it. Tight
/// pockets (a node wedged between neighbors) are out of scope - a node-placement
/// concern, not routing.
@MainActor
struct PolicyCanvasSelectiveDragBodyHitTests {
  /// Load the Default sample exactly as the lab does: `load(...)` runs the clean
  /// initial layout and carries the document's saved routing hints / precomputed
  /// routes. The lab does NOT force a reflow, so a forced reflow here would route
  /// a different graph than the user sees on screen.
  private func loadedDefault() -> PolicyCanvasViewModel {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(
      document: PolicyCanvasLabSamples.realDefault, simulation: nil, audit: nil
    )
    return viewModel
  }

  /// `hinted: true` carries the document's saved routing hints / precomputed
  /// routes - the at-rest geometry the canvas shows and seeds the drag cache
  /// with. `hinted: false` mirrors an in-flight drag and the drop: the first
  /// drag tick nils both via `bumpLayoutGeneration`, so every moved-position
  /// route runs hint-free.
  private func input(
    nodes: [PolicyCanvasNode], viewModel: PolicyCanvasViewModel, hinted: Bool
  ) -> PolicyCanvasRouteWorkerInput {
    PolicyCanvasRouteWorkerInput(
      nodes: nodes,
      groups: viewModel.groups,
      edges: viewModel.edges,
      fontScale: 1,
      routingHints: hinted ? viewModel.routingHints : nil,
      precomputedRoutes: hinted ? viewModel.precomputedRoutes : nil,
      algorithmSelection: viewModel.algorithmSelection
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

  /// True when the moved node lacks room to route around at this position -
  /// either it overlaps another body or it sits in a cluster/pocket where a
  /// neighbor is within a node body's clearance on some side. A drop on top of,
  /// wedged between, or ringed by other nodes inevitably crosses wires for a
  /// node-placement reason, not a routing one (the only clean route would be a
  /// long detour fully around the cluster, which needs a full visibility-graph
  /// router - see docs/research/policy-canvas-router-replacement-2026-06-21.md).
  /// Those positions are out of scope for the body-routing invariant. The margin
  /// is a node's own short dimension: an open drop has at least that much clear
  /// space on every side, enough for a wire to jog around the body. The
  /// screenshot case (a node dragged into clearly open space) is in scope.
  private func movedNodeIsConstrained(
    _ nodes: [PolicyCanvasNode], movedID: String, viewModel: PolicyCanvasViewModel
  ) -> Bool {
    let clearance = PolicyCanvasLayout.nodeMinimumHeight
    let sizes = PolicyCanvasLayout.nodeSizes(for: nodes, edges: viewModel.edges)
    func frame(_ node: PolicyCanvasNode) -> CGRect {
      let size = sizes[node.id] ?? PolicyCanvasLayout.nodeSize(for: node)
      return CGRect(origin: node.position, size: size)
    }
    guard let moved = nodes.first(where: { $0.id == movedID }) else {
      return false
    }
    let lane = frame(moved).insetBy(dx: -clearance, dy: -clearance)
    return nodes.contains { $0.id != movedID && frame($0).intersects(lane) }
  }

  /// Keys for wires whose end sits away from their rendered port dot - the
  /// detached-port signal the canvas shows as a dot stranded off the node body.
  private func detachmentKeys(
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
    for violation in report.portSpacing where violation.kind == .detached {
      keys.insert(violation.edgeIDs.sorted().joined(separator: "+") + " @ " + violation.nodeID)
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
      input: input(nodes: viewModel.nodes, viewModel: viewModel, hinted: true)
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
          input: input(nodes: moved, viewModel: viewModel, hinted: false)
        )
        let fullHits = bodyHitKeys(full, nodes: moved, viewModel: viewModel)
        let displayedHits = bodyHitKeys(displayed, nodes: moved, viewModel: viewModel)
        let extra = displayedHits.subtracting(fullHits).sorted()
        let source = live != nil ? "selective" : "translate"
        if !extra.isEmpty {
          failures.append("pos \(Int(x)),\(Int(y)) [\(source)] body: " + extra.joined(separator: ", "))
        }
        // The drop commits the full route. If that route itself crosses the
        // moved node's body, the wire stays behind the body after release - the
        // crossing the user reported persists after the drag. This is a base
        // router defect, not a drag-path one, so assert the drop is clean of
        // moved-body crossings outright (not just relative to the displayed).
        // Only assert open-space drops. A node dropped on top of another body
        // inevitably crosses wires (a node-overlap problem, not routing), so
        // those positions are out of scope for the body-routing invariant.
        let dropMovedHits = fullHits.filter { $0.hasSuffix(" -> " + movedID) }.sorted()
        if !dropMovedHits.isEmpty,
          !movedNodeIsConstrained(moved, movedID: movedID, viewModel: viewModel)
        {
          failures.append("pos \(Int(x)),\(Int(y)) [drop-open] body: " + dropMovedHits.joined(separator: ", "))
        }
        let fullDetach = detachmentKeys(full, nodes: moved, viewModel: viewModel)
        let displayedDetach = detachmentKeys(displayed, nodes: moved, viewModel: viewModel)
        let extraDetach = displayedDetach.subtracting(fullDetach).sorted()
        if !extraDetach.isEmpty {
          failures.append("pos \(Int(x)),\(Int(y)) [\(source)] detach: " + extraDetach.joined(separator: ", "))
        }
        y += 120
      }
      x += 120
    }

    let message = "\(failures.count) crossing positions:\n" + failures.prefix(40).joined(separator: "\n")
    #expect(failures.isEmpty, Comment(rawValue: message))
  }

  /// The grid sweep above feeds a fixed clean baseline as `previous` at every
  /// position. The live app does not: the async coalescer commits each frame's
  /// selective output to the cache, and the next frame's sync display reads that
  /// cache back as `previous`. So `previous` is an evolving selective result for
  /// a nearby node position, not the original full route - and the crossed-edge
  /// fold keys off `previous`'s geometry, so a stale detour can hide the crossing
  /// from the fold while the moved body still sits on the frozen wire. This drags
  /// the branch-protection terminal straight up out of its lane one gesture step
  /// at a time, feeding each frame's displayed output back in as the next frame's
  /// `previous`, and guards that no frame shows the moved body slicing a wire.
  @Test("evolving previous drag path never shows the moved body crossing a wire")
  func evolvingPreviousDragPathNeverCrossesABody() async throws {
    let viewModel = loadedDefault()
    let movedID = "supervisor:merge-deny:branch-protection"
    guard let movedIndex = viewModel.nodes.firstIndex(where: { $0.id == movedID }) else {
      Issue.record("branch-protection terminal not found in Default sample")
      return
    }
    let home = viewModel.nodes[movedIndex].position
    var previous = await PolicyCanvasRouteWorker().compute(
      input: input(nodes: viewModel.nodes, viewModel: viewModel, hinted: true)
    )

    var failures: [String] = []
    for column in [home.x - 200, home.x, home.x + 200] {
      previous = await PolicyCanvasRouteWorker().compute(
        input: input(nodes: viewModel.nodes, viewModel: viewModel, hinted: true)
      )
      var step = 0
      while step <= 18 {
        let y = home.y - CGFloat(step) * 40
        var moved = viewModel.nodes
        moved[movedIndex].position = CGPoint(x: column, y: y)

        let live = policyCanvasLiveDragRoutedOutput(
          nodes: moved,
          groups: viewModel.groups,
          edges: viewModel.edges,
          fontScale: 1,
          algorithmSelection: viewModel.algorithmSelection,
          movedNodeIDs: [movedID],
          previous: previous
        )
        let displayed = live ?? previous
        let full = await PolicyCanvasRouteWorker().compute(
          input: input(nodes: moved, viewModel: viewModel, hinted: false)
        )
        let movedHits = bodyHitKeys(displayed, nodes: moved, viewModel: viewModel)
          .filter { $0.hasSuffix(" -> " + movedID) }
        let fullMovedHits = bodyHitKeys(full, nodes: moved, viewModel: viewModel)
          .filter { $0.hasSuffix(" -> " + movedID) }
        let extraHits = movedHits.subtracting(fullMovedHits).sorted()
        if !extraHits.isEmpty {
          failures.append("col \(Int(column)) y \(Int(y)) body: " + extraHits.joined(separator: ", "))
        }
        let displayedDetach = detachmentKeys(displayed, nodes: moved, viewModel: viewModel)
        let fullDetach = detachmentKeys(full, nodes: moved, viewModel: viewModel)
        let extraDetach = displayedDetach.subtracting(fullDetach).sorted()
        if !extraDetach.isEmpty {
          failures.append("col \(Int(column)) y \(Int(y)) detach: " + extraDetach.joined(separator: ", "))
        }
        previous = displayed
        step += 1
      }
    }

    let message = "\(failures.count) crossing frames:\n" + failures.prefix(40).joined(separator: "\n")
    #expect(failures.isEmpty, Comment(rawValue: message))
  }
}
