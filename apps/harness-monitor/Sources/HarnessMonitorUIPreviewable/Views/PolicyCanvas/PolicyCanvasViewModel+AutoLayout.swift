import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

private struct PolicyCanvasReflowSnapshot {
  let nodes: [PolicyCanvasNode]
  let edges: [PolicyCanvasEdge]
  let routingHints: PolicyCanvasLayoutRoutingHints?
}

extension PolicyCanvasViewModel {
  var canReflowLayout: Bool {
    !nodes.isEmpty
  }

  @discardableResult
  func restoreMissingRoutingHintsForCurrentLayout() -> Bool {
    guard routingHints?.isEmpty != false else {
      return false
    }
    return refreshRoutingHints(
      to: policyCanvasRoutingHintsForCurrentLayout(
        nodes: nodes,
        groups: groups,
        edges: edges
      )
    )
  }

  @discardableResult
  func refreshRoutingHints(to nextRoutingHints: PolicyCanvasLayoutRoutingHints?) -> Bool {
    guard routingHints != nextRoutingHints else {
      return false
    }
    routingHints = nextRoutingHints
    return true
  }

  func reflowLayout(
    preserveManualAnchors: Bool = true,
    force: Bool = false,
    requestsRouteComputation: Bool = true
  ) {
    guard !nodes.isEmpty else {
      notifyStatus("Add nodes before reflowing the layout")
      return
    }
    let requestExplicitRoutesIfNeeded = { [self] in
      if requestsRouteComputation {
        requestRouteComputation()
      }
    }
    let preservesManualAnchors = shouldPreserveManualAnchors(preserveManualAnchors)
    // Reformat re-runs the layered engine, whose depth-based output spreads a
    // hand-authored policy graph across the canvas. When the current layout is
    // already valid - no node or group overlaps and every node sits inside its
    // assigned group - and there are no auto-placed nodes that need to repack
    // around manual anchors, keep the arrangement the user sees instead of
    // replacing a tidy saved layout with the engine's spread. This mirrors
    // initial load, which only auto-arranges a layout that needs it.
    // `force` overrides this for surfaces (the Policy Canvas Lab) that always
    // want the engine's best placement rather than the persisted coordinates.
    guard shouldReflowLayout(force: force, preservesManualAnchors: preservesManualAnchors) else {
      finishNoOpReflow(
        nextRoutingHints: nil,
        requestsRouteComputation: requestsRouteComputation,
        status: "Layout already tidy"
      )
      return
    }
    guard
      let reflowSnapshot = makeReflowSnapshot(preservesManualAnchors: preservesManualAnchors)
    else {
      notifyStatus("Layout could not be reflowed")
      return
    }
    applyReflowSnapshot(
      reflowSnapshot,
      requestsRouteComputation: requestsRouteComputation,
      requestExplicitRoutesIfNeeded: requestExplicitRoutesIfNeeded
    )
  }

  private func shouldPreserveManualAnchors(_ preserveManualAnchors: Bool) -> Bool {
    let hasManualAnchors = nodes.contains { $0.layoutSource == .manual }
    let hasAutoPlacedNodes = nodes.contains { $0.layoutSource == .auto }
    return preserveManualAnchors && hasManualAnchors && hasAutoPlacedNodes
  }

  private func shouldReflowLayout(
    force: Bool,
    preservesManualAnchors: Bool
  ) -> Bool {
    force
      || preservesManualAnchors
      || policyCanvasNeedsDefaultArrangement(nodes: nodes, groups: groups)
  }

  private func finishNoOpReflow(
    nextRoutingHints: PolicyCanvasLayoutRoutingHints?,
    requestsRouteComputation: Bool,
    status: String
  ) {
    if let nextRoutingHints, routingHints?.isEmpty != false {
      refreshRoutingHints(to: nextRoutingHints)
    } else {
      restoreMissingRoutingHintsForCurrentLayout()
    }
    if requestsRouteComputation {
      requestRouteComputation()
      requestViewportCentering(.documentAfterRouteComputation)
    }
    notifyStatus(status)
  }

  private func makeReflowSnapshot(
    preservesManualAnchors: Bool
  ) -> PolicyCanvasReflowSnapshot? {
    var nextNodes = nodes
    var nextGroups = groups
    guard
      let result = policyCanvasAutomaticLayoutResult(
        nodes: nextNodes,
        groups: nextGroups,
        edges: edges,
        // Reformat always seeds within-layer order from the current geometry, so
        // an already-laid-out graph reproduces itself instead of reshuffling -
        // whether its positions came from a prior auto layout or trusted saved
        // coordinates loaded as manual.
        mode: .explicitReflow(preserveManualAnchors: preservesManualAnchors),
        algorithmSelection: algorithmSelection
      )
    else {
      return nil
    }
    let nextRoutingHints = applyPolicyCanvasLayoutResult(
      result,
      nodes: &nextNodes,
      groups: &nextGroups,
      centerInMinimumCanvas: !preservesManualAnchors
    )
    if policyCanvasUsesSingleFedTerminalAlignment(algorithmSelection) {
      policyCanvasAlignSingleFedTerminals(nodes: &nextNodes, groups: &nextGroups, edges: edges)
    }
    let nextEdges = edges.map { edge in
      policyCanvasApplyingPreferredPortSides(
        edge,
        nodes: nextNodes,
        preservesPinnedState: true
      )
    }
    return PolicyCanvasReflowSnapshot(
      nodes: nextNodes,
      edges: nextEdges,
      routingHints: nextRoutingHints
    )
  }

  private func applyReflowSnapshot(
    _ snapshot: PolicyCanvasReflowSnapshot,
    requestsRouteComputation: Bool,
    requestExplicitRoutesIfNeeded: () -> Void
  ) {
    let nodeChanges = reflowNodeChanges(to: snapshot.nodes)
    let edgeChanges = reflowEdgeChanges(to: snapshot.edges)

    guard !nodeChanges.isEmpty || !edgeChanges.isEmpty else {
      finishNoOpReflow(
        nextRoutingHints: snapshot.routingHints,
        requestsRouteComputation: requestsRouteComputation,
        status: "Layout already matches the current anchors"
      )
      return
    }

    mutate(
      .reflowLayout(
        nodeChanges: nodeChanges,
        edgeChanges: edgeChanges,
        fromRoutingHints: routingHints,
        toRoutingHints: snapshot.routingHints
      )
    )
    requestExplicitRoutesIfNeeded()
    // A reflow relocates every node, so the scroll position the viewport held
    // for the previous layout now frames empty canvas. Recenter on the fresh
    // layout, exactly as a document load does.
    requestViewportCentering(
      requestsRouteComputation ? .documentAfterRouteComputation : .document
    )
  }

  private func reflowNodeChanges(
    to nextNodes: [PolicyCanvasNode]
  ) -> [PolicyCanvasReflowNodeChange] {
    let currentNodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    return nextNodes.compactMap { node in
      guard let current = currentNodesByID[node.id] else {
        return nil
      }
      guard
        current.position != node.position
          || current.layoutSource != node.layoutSource
      else {
        return nil
      }
      return PolicyCanvasReflowNodeChange(
        id: node.id,
        fromPosition: current.position,
        toPosition: node.position,
        fromLayoutSource: current.layoutSource,
        toLayoutSource: node.layoutSource
      )
    }
  }

  private func reflowEdgeChanges(
    to nextEdges: [PolicyCanvasEdge]
  ) -> [PolicyCanvasEdgeReflowChange] {
    let currentEdgesByID = Dictionary(uniqueKeysWithValues: edges.map { ($0.id, $0) })
    return nextEdges.compactMap { edge in
      guard let current = currentEdgesByID[edge.id], current != edge else {
        return nil
      }
      return PolicyCanvasEdgeReflowChange(id: edge.id, from: current, to: edge)
    }
  }
}
