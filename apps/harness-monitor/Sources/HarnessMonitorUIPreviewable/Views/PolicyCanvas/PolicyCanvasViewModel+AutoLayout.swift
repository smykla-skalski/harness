import SwiftUI

extension PolicyCanvasViewModel {
  var canReflowLayout: Bool {
    !nodes.isEmpty
  }

  func reflowLayout(preserveManualAnchors: Bool = true, force: Bool = false) {
    guard !nodes.isEmpty else {
      notifyStatus("Add nodes before reflowing the layout")
      return
    }
    // Reformat re-runs the layered engine, whose depth-based output spreads a
    // hand-authored policy graph across the canvas. When the current layout is
    // already valid - no node or group overlaps and every node sits inside its
    // assigned group - there is nothing to fix, so keep the arrangement the user
    // sees instead of replacing a tidy saved layout with the engine's spread.
    // This mirrors initial load, which only auto-arranges a layout that needs it.
    // `force` overrides this for surfaces (the Policy Canvas Lab) that always
    // want the engine's best placement rather than the persisted coordinates.
    guard force || policyCanvasNeedsDefaultArrangement(nodes: nodes, groups: groups) else {
      notifyStatus("Layout already tidy")
      return
    }
    let hasManualAnchors = nodes.contains { $0.layoutSource == .manual }
    let hasAutoPlacedNodes = nodes.contains { $0.layoutSource == .auto }
    let preservesManualAnchors =
      preserveManualAnchors
      && hasManualAnchors
      && hasAutoPlacedNodes
    let centersInMinimumCanvas = !preservesManualAnchors

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
        mode: .explicitReflow(preserveManualAnchors: preservesManualAnchors)
      )
    else {
      notifyStatus("Layout could not be reflowed")
      return
    }
    let nextRoutingHints = applyPolicyCanvasLayoutResult(
      result,
      nodes: &nextNodes,
      groups: &nextGroups,
      centerInMinimumCanvas: centersInMinimumCanvas
    )
    policyCanvasAlignSingleFedTerminals(nodes: &nextNodes, groups: &nextGroups, edges: edges)
    let nextEdges = edges.map { edge in
      policyCanvasApplyingPreferredPortSides(
        edge,
        nodes: nextNodes,
        preservesPinnedState: true
      )
    }

    let currentNodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    let nodeChanges = nextNodes.compactMap { node -> PolicyCanvasReflowNodeChange? in
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

    let currentEdgesByID = Dictionary(uniqueKeysWithValues: edges.map { ($0.id, $0) })
    let edgeChanges = nextEdges.compactMap { edge -> PolicyCanvasEdgeReflowChange? in
      guard let current = currentEdgesByID[edge.id], current != edge else {
        return nil
      }
      return PolicyCanvasEdgeReflowChange(id: edge.id, from: current, to: edge)
    }

    guard !nodeChanges.isEmpty || !edgeChanges.isEmpty else {
      notifyStatus("Layout already matches the current anchors")
      return
    }

    mutate(
      .reflowLayout(
        nodeChanges: nodeChanges,
        edgeChanges: edgeChanges,
        fromRoutingHints: routingHints,
        toRoutingHints: nextRoutingHints
      )
    )
    // A reflow relocates every node, so the scroll position the viewport held
    // for the previous layout now frames empty canvas - this is what makes a
    // canvas switch (the lab/picker force-reflows on switch) or a manual Reformat
    // land on blank space. Recenter on the fresh layout, exactly as a document
    // load does. The viewport defers the scroll until the new route data lands
    // (`centerViewportIfNeeded` gates on `appliedRouteKey == currentRouteKey`), so
    // this never centers on stale pre-reflow geometry.
    requestViewportCentering(.document)
  }
}

/// Slide each single-fed branch terminal under the point where its one feeder
/// leaves the source, so the drop is a straight line instead of a jog. A terminal
/// fed from the source's bottom centers on that bottom port; one fed from the
/// trailing edge centers on the trailing exit column (one fed from the leading
/// edge mirrors). Sources that fan three or more children below them keep the
/// comb's even spread - their feeders diverge from packed bottom ports, so pulling
/// each child under its own port would overlap them and the bottom fan already
/// reads cleanly. Per terminal row the aligned terminals are pushed apart to one
/// column step, left to right, so alignment never drops one onto another. The side
/// test mirrors the route worker's `policyCanvasGeometryAwareSourceSide`, so a
/// terminal is only pulled where its rendered rail actually leaves the source.
func policyCanvasAlignSingleFedTerminals(
  nodes: inout [PolicyCanvasNode],
  groups: inout [PolicyCanvasGroup],
  edges: [PolicyCanvasEdge]
) {
  let nodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
  func frame(_ node: PolicyCanvasNode) -> CGRect {
    CGRect(origin: node.position, size: PolicyCanvasLayout.nodeSize)
  }
  func side(_ source: PolicyCanvasNode, _ target: PolicyCanvasNode) -> PolicyCanvasPortSide {
    policyCanvasGeometryAwareSourceSide(
      natural: .trailing, sourceFrame: frame(source), targetFrame: frame(target))
  }
  var belowChildren: [String: Set<String>] = [:]
  for edge in edges {
    guard let source = nodesByID[edge.source.nodeID], let target = nodesByID[edge.target.nodeID]
    else { continue }
    if frame(target).minY > frame(source).maxY {
      belowChildren[source.id, default: []].insert(target.id)
    }
  }
  let incomingByTarget = Dictionary(grouping: edges, by: { $0.target.nodeID })
  let lead = PolicyCanvasLayout.edgePortTurnMinimumLead
  var desiredCenterX: [String: CGFloat] = [:]
  for node in nodes where node.outputPorts.isEmpty {
    guard
      let incoming = incomingByTarget[node.id], incoming.count == 1, let edge = incoming.first,
      let source = nodesByID[edge.source.nodeID],
      (belowChildren[source.id]?.count ?? 0) < 3,
      frame(node).minY > frame(source).maxY
    else { continue }
    switch side(source, node) {
    case .bottom:
      let bottomEdges = source.outputPorts.compactMap { port -> PolicyCanvasEdge? in
        edges.first {
          $0.source.nodeID == source.id && $0.source.portID == port.id
            && (nodesByID[$0.target.nodeID].map { side(source, $0) == .bottom } ?? false)
        }
      }
      guard let index = bottomEdges.firstIndex(where: { $0.id == edge.id }) else { continue }
      desiredCenterX[node.id] =
        source.position.x + PolicyCanvasLayout.portX(index: index, count: bottomEdges.count)
    case .trailing:
      desiredCenterX[node.id] = frame(source).maxX + lead
    case .leading:
      desiredCenterX[node.id] = frame(source).minX - lead
    default:
      continue
    }
  }
  guard !desiredCenterX.isEmpty else { return }
  let half = PolicyCanvasLayout.nodeSize.width / 2
  let step = PolicyCanvasLayout.nodeSize.width + lead
  let rows = Dictionary(grouping: desiredCenterX.keys) {
    Int((nodesByID[$0]?.position.y ?? 0).rounded())
  }
  var finalX: [String: CGFloat] = [:]
  for ids in rows.values {
    let ordered = ids.sorted { (desiredCenterX[$0] ?? 0) < (desiredCenterX[$1] ?? 0) }
    var previousCenter = -CGFloat.greatestFiniteMagnitude
    for id in ordered {
      let center = max(desiredCenterX[id] ?? 0, previousCenter + step)
      finalX[id] = center - half
      previousCenter = center
    }
  }
  // Apply each terminal's alignment only if it keeps the layout tidy. Sliding a
  // terminal under its feeder for a straight drop is kept; a move that would push
  // its group into a neighbor (leaving Reformat non-convergent, since the gate
  // would still flag the layout and a second press would shift the terminal back)
  // is refused, and that terminal stays at the engine's already-clean placement.
  // Admitting them one at a time preserves the good alignments instead of
  // abandoning all of them when a single terminal would overlap.
  let alignedIDs = finalX.keys.sorted()
  let indexByID = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1.id, $0) })
  for id in alignedIDs {
    guard let index = indexByID[id], let x = finalX[id] else { continue }
    let original = nodes[index].position
    nodes[index].position = CGPoint(x: x.rounded(), y: original.y)
    policyCanvasReencloseGroupFrames(nodes: nodes, groups: &groups)
    if policyCanvasNeedsDefaultArrangement(nodes: nodes, groups: groups) {
      nodes[index].position = original
      policyCanvasReencloseGroupFrames(nodes: nodes, groups: &groups)
    }
  }
}

/// Rebuilds each group's frame to enclose its current members, matching the
/// engine's own `policyCanvasGroupFrame` padding so a re-enclosed frame is
/// identical to one the layered engine would have produced for those positions.
func policyCanvasReencloseGroupFrames(
  nodes: [PolicyCanvasNode],
  groups: inout [PolicyCanvasGroup]
) {
  var membersByGroup: [String: [PolicyCanvasNode]] = [:]
  for node in nodes {
    if let groupID = node.groupID {
      membersByGroup[groupID, default: []].append(node)
    }
  }
  for index in groups.indices {
    if let frame = policyCanvasGroupFrame(containing: membersByGroup[groups[index].id] ?? []) {
      groups[index].frame = frame
    }
  }
}
