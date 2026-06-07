import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

private struct PolicyCanvasReflowSnapshot {
  let nodes: [PolicyCanvasNode]
  let groups: [PolicyCanvasGroup]
  let edges: [PolicyCanvasEdge]
  let routingHints: PolicyCanvasLayoutRoutingHints?
}

/// The layout `reflowLayout(...)` would commit, surfaced without mutating the
/// model so the hosting viewport can route it before publishing. Carries the
/// reconciled groups too, since routing treats the container box title as an
/// obstacle.
struct PolicyCanvasReflowGraph {
  let nodes: [PolicyCanvasNode]
  let groups: [PolicyCanvasGroup]
  let edges: [PolicyCanvasEdge]
  let routingHints: PolicyCanvasLayoutRoutingHints?
}

/// A pending reformat raised by `requestAtomicReflow(...)`. The viewport
/// observes `id` changes, plans the layout, routes it off-main, and reveals the
/// new nodes and wires together.
struct PolicyCanvasAtomicReflowRequest: Equatable {
  let id: UInt64
  let preserveManualAnchors: Bool
  let force: Bool
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
    if force, !preservesManualAnchors, isCurrentCanonicalForcedReflow() {
      finishNoOpReflow(
        nextRoutingHints: nil,
        requestsRouteComputation: requestsRouteComputation,
        status: "Layout already matches the current anchors"
      )
      return
    }
    guard
      let reflowSnapshot = makeReflowSnapshot(
        preservesManualAnchors: preservesManualAnchors,
        force: force
      )
    else {
      notifyStatus("Layout could not be reflowed")
      return
    }
    let canonicalForcedSignature =
      force && !preservesManualAnchors
      ? reflowSnapshotSignature(reflowSnapshot)
      : nil
    applyReflowSnapshot(
      reflowSnapshot,
      requestsRouteComputation: requestsRouteComputation,
      requestExplicitRoutesIfNeeded: requestExplicitRoutesIfNeeded
    )
    if let canonicalForcedSignature {
      lastCanonicalForcedReflowSignature = canonicalForcedSignature
    }
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
    preservesManualAnchors: Bool,
    force: Bool
  ) -> PolicyCanvasReflowSnapshot? {
    if force, !preservesManualAnchors {
      return makeSingleReflowSnapshot(
        nodes: nodes,
        groups: groups,
        edges: edges,
        preservesManualAnchors: false
      )
    }
    return makeSingleReflowSnapshot(
      nodes: nodes,
      groups: groups,
      edges: edges,
      preservesManualAnchors: preservesManualAnchors
    )
  }

  private func makeSingleReflowSnapshot(
    nodes inputNodes: [PolicyCanvasNode],
    groups inputGroups: [PolicyCanvasGroup],
    edges inputEdges: [PolicyCanvasEdge],
    preservesManualAnchors: Bool
  ) -> PolicyCanvasReflowSnapshot? {
    var nextNodes = inputNodes
    var nextGroups = inputGroups
    guard
      let result = policyCanvasAutomaticLayoutResult(
        nodes: nextNodes,
        groups: nextGroups,
        edges: inputEdges,
        // Reflow keeps current row order because it produces the best low-crossing
        // seed for the engine. Forced full reformat records the chosen output's
        // signature so repeated presses become a fixed point.
        mode: .explicitReflow(preserveManualAnchors: preservesManualAnchors),
        algorithmSelection: algorithmSelection
      )
    else {
      return nil
    }
    var nextRoutingHints = applyPolicyCanvasLayoutResult(
      result,
      nodes: &nextNodes,
      groups: &nextGroups,
      centerInMinimumCanvas: !preservesManualAnchors
    )
    if policyCanvasUsesSingleFedTerminalAlignment(algorithmSelection) {
      policyCanvasAlignSingleFedTerminals(
        nodes: &nextNodes,
        groups: &nextGroups,
        edges: inputEdges
      )
    }
    if policyCanvasResolveGroupedNodeOverlaps(nodes: &nextNodes, groups: &nextGroups) {
      nextRoutingHints = policyCanvasRoutingHintsForCurrentLayout(
        nodes: nextNodes,
        groups: nextGroups,
        edges: inputEdges
      )
    }
    let nextEdges = inputEdges.map { edge in
      policyCanvasApplyingPreferredPortSides(
        edge,
        nodes: nextNodes,
        preservesPinnedState: true
      )
    }
    return PolicyCanvasReflowSnapshot(
      nodes: nextNodes,
      groups: nextGroups,
      edges: nextEdges,
      routingHints: nextRoutingHints
    )
  }

  private func isCurrentCanonicalForcedReflow() -> Bool {
    guard let lastCanonicalForcedReflowSignature else {
      return false
    }
    return lastCanonicalForcedReflowSignature
      == canonicalForcedReflowSignature(
        nodes: nodes,
        groups: groups,
        edges: edges,
        routingHints: routingHints
      )
  }

  private func reflowSnapshotSignature(_ snapshot: PolicyCanvasReflowSnapshot) -> String {
    canonicalForcedReflowSignature(
      nodes: snapshot.nodes,
      groups: snapshot.groups,
      edges: snapshot.edges,
      routingHints: snapshot.routingHints
    )
  }

  private func canonicalForcedReflowSignature(
    nodes: [PolicyCanvasNode],
    groups: [PolicyCanvasGroup],
    edges: [PolicyCanvasEdge],
    routingHints: PolicyCanvasLayoutRoutingHints?
  ) -> String {
    var parts: [String] = []
    parts.reserveCapacity(nodes.count + groups.count + edges.count + 1)
    parts.append("a:\(String(describing: algorithmSelection))")
    for node in nodes.sorted(by: { $0.id < $1.id }) {
      let layoutSource = node.layoutSource.map { String(describing: $0) } ?? "nil"
      parts.append(
        "n:\(node.id):\(reflowSignatureCoordinate(node.position.x)):"
          + "\(reflowSignatureCoordinate(node.position.y)):\(layoutSource)"
      )
    }
    for group in groups.sorted(by: { $0.id < $1.id }) {
      parts.append(
        "g:\(group.id):\(reflowSignatureCoordinate(group.frame.minX)):"
          + "\(reflowSignatureCoordinate(group.frame.minY)):"
          + "\(reflowSignatureCoordinate(group.frame.width)):"
          + "\(reflowSignatureCoordinate(group.frame.height))"
      )
    }
    for edge in edges.sorted(by: { $0.id < $1.id }) {
      let sourceSide = edge.source.side.map { String(describing: $0) } ?? "nil"
      let targetSide = edge.target.side.map { String(describing: $0) } ?? "nil"
      parts.append(
        "e:\(edge.id):\(sourceSide):\(targetSide):\(edge.pinnedPortSide)"
      )
    }
    for (edgeID, hint) in (routingHints?.edgeHints ?? [:]).sorted(by: { $0.key < $1.key }) {
      parts.append(
        "h:\(edgeID):\(hint.key.sourceScopeID):\(hint.key.targetScopeID):"
          + "\(hint.key.targetNodeID):\(hint.key.label):\(hint.key.laneIndex):"
          + "\(reflowSignatureCoordinate(hint.horizontalLaneY)):"
          + "\(hint.verticalLaneX.map(reflowSignatureCoordinate) ?? "nil"):"
          + "\(hint.bundleOrdinal):\(hint.bundleSize)"
      )
    }
    return parts.joined(separator: "|")
  }

  private func reflowSignatureCoordinate(_ value: CGFloat) -> String {
    String(Int(value.rounded()))
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

  /// Compute the layout `reflowLayout(...)` would commit, without mutating the
  /// model, so the viewport can route it before publishing. Returns nil for an
  /// empty graph or a layout that would not change; the caller then falls back
  /// to a plain reflow whose own no-op handling covers status and centering.
  /// Deterministic given the model state, so the committed layout reproduces
  /// this graph exactly and the routes computed from it stay valid.
  func plannedReflowGraph(
    preserveManualAnchors: Bool,
    force: Bool
  ) -> PolicyCanvasReflowGraph? {
    guard !nodes.isEmpty else {
      return nil
    }
    let preservesManualAnchors = shouldPreserveManualAnchors(preserveManualAnchors)
    guard shouldReflowLayout(force: force, preservesManualAnchors: preservesManualAnchors) else {
      return nil
    }
    if force, !preservesManualAnchors, isCurrentCanonicalForcedReflow() {
      return nil
    }
    guard
      let snapshot = makeReflowSnapshot(
        preservesManualAnchors: preservesManualAnchors,
        force: force
      )
    else {
      return nil
    }
    return PolicyCanvasReflowGraph(
      nodes: snapshot.nodes,
      groups: snapshot.groups,
      edges: snapshot.edges,
      routingHints: snapshot.routingHints
    )
  }
}
