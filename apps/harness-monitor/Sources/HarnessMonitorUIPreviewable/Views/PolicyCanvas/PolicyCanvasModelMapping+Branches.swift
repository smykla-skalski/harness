import HarnessMonitorKit
import SwiftUI

/// Identity of a parallel-edge family: edges that share both endpoints
/// (source node+port and target node+port) are one logical transition the
/// daemon split into several reason-code branches, so the canvas draws them as
/// a single merged wire. The label is never part of the key - preview fixtures
/// give the four fail edges distinct labels while the live policy shares one,
/// and a label-keyed fold would diverge between them.
struct PolicyCanvasFanInKey: Hashable {
  let sourceNodeID: String
  let sourcePortID: String
  let targetNodeID: String
  let targetPortID: String

  init(_ edge: PolicyCanvasEdge) {
    sourceNodeID = edge.source.nodeID
    sourcePortID = edge.source.portID
    targetNodeID = edge.target.nodeID
    targetPortID = edge.target.portID
  }
}

/// Fold parallel edges that share both endpoints into one merged edge, leaving
/// singletons untouched and preserving first-seen order. Runs on load before
/// port-side assignment so routing, markers, selection, and the label layer all
/// treat a convergent family as a single wire - one clean L into one port -
/// instead of the cramped nested rails the per-edge family router drew.
func policyCanvasFoldParallelBranches(_ edges: [PolicyCanvasEdge]) -> [PolicyCanvasEdge] {
  var order: [PolicyCanvasFanInKey] = []
  var groups: [PolicyCanvasFanInKey: [PolicyCanvasEdge]] = [:]
  for edge in edges {
    let key = PolicyCanvasFanInKey(edge)
    if groups[key] == nil {
      order.append(key)
    }
    groups[key, default: []].append(edge)
  }
  return order.map { key in
    let group = groups[key] ?? []
    return group.count > 1 ? policyCanvasMergedEdge(group) : group[0]
  }
}

/// Collapse a parallel family into one merged edge carrying the union of its
/// branches. The summary label is the shared branch label when the family
/// agrees (the live policy shares "evidence failure") and empty when the
/// branches disagree - the per-branch labels then live in the inspector and the
/// accessibility description rather than colliding on one wire. Kind escalates
/// to the most urgent branch so a family containing any error path renders as
/// the error stroke and stays pinned. The merged id is deterministic and
/// independent of branch order; a single-branch tuple never reaches here, so
/// non-merged edges keep their daemon id.
func policyCanvasMergedEdge(_ group: [PolicyCanvasEdge]) -> PolicyCanvasEdge {
  let first = group[0]
  let branches = group.flatMap(\.branches)
  let labels = Set(branches.map(\.label))
  let mergedLabel = labels.count == 1 ? (labels.first ?? "") : ""
  let conditions = Set(branches.map(\.condition))
  let mergedCondition = conditions.count == 1 ? (conditions.first ?? first.condition) : first.condition
  let mergedKind: PolicyCanvasEdgeKind =
    group.contains { $0.kind == .error }
    ? .error : group.contains { $0.kind == .control } ? .control : .flow
  let key = PolicyCanvasFanInKey(first)
  let mergedID =
    "merged:\(key.sourceNodeID)|\(key.sourcePortID)|\(key.targetNodeID)|\(key.targetPortID)"
  return PolicyCanvasEdge(
    id: mergedID,
    source: first.source,
    target: first.target,
    label: mergedLabel,
    condition: mergedCondition,
    pinnedPortSide: group.contains(where: \.pinnedPortSide),
    kind: mergedKind,
    isAnimated: group.contains(where: \.isAnimated),
    branches: branches
  )
}

/// Expand a (possibly merged) edge back into its daemon edges, one per branch.
/// A non-merged edge yields one daemon edge byte-identical to today; a merged
/// edge yields N, each re-emitting its branch's daemon id, reason code,
/// condition, label, and target. Actions are preserved by daemon edge id via
/// `originalConditions` (there is no actions editor, so dropping them would be
/// data loss). The `if_then_else` then/else boolean condition export is applied
/// per branch from the shared source port.
func policyCanvasDaemonEdges(
  for edge: PolicyCanvasEdge,
  nodes: [PolicyCanvasNode],
  originalConditions: [String: TaskBoardPolicyPipelineEdgeCondition]
) -> [TaskBoardPolicyPipelineEdge] {
  let sourceNode = nodes.first { $0.id == edge.source.nodeID }
  // Non-merged: the edge's own fields are the editable truth - the inspector
  // writes edge.condition/label/target directly - so export the edge as-is via
  // the shared single-edge builder (switch-port persistence, boolean branches).
  guard edge.isMerged else {
    return [
      taskBoardPolicyEdge(
        edge,
        sourceNode: sourceNode,
        targetNode: nodes.first { $0.id == edge.target.nodeID },
        originalCondition: originalConditions[edge.id]
      )
    ]
  }
  // Merged: re-emit one daemon edge per branch, each keeping its own daemon id,
  // condition, label, and target. Reusing taskBoardPolicyEdge means the merged
  // expansion gets the same port persistence and condition export as any edge.
  return edge.branches.map { branch in
    let branchEdge = PolicyCanvasEdge(
      id: branch.daemonEdgeID,
      source: edge.source,
      target: branch.target,
      label: branch.label,
      condition: branch.condition,
      pinnedPortSide: edge.pinnedPortSide,
      kind: edge.kind,
      isAnimated: edge.isAnimated,
      reasonCode: branch.reasonCode
    )
    return taskBoardPolicyEdge(
      branchEdge,
      sourceNode: sourceNode,
      targetNode: nodes.first { $0.id == branch.target.nodeID },
      originalCondition: originalConditions[branch.daemonEdgeID]
    )
  }
}

/// Build the daemon edge condition for an exported edge: an if_then_else
/// then/else port becomes the boolean `condition_true`/`condition_false`, and
/// everything else carries the edge's condition string with the actions and
/// reason code preserved from the original daemon edge. Lives next to the branch
/// expander (rather than in the mapping file) because that is its only caller.
func policyCanvasExportedEdgeCondition(
  _ edge: PolicyCanvasEdge,
  sourceNode: PolicyCanvasNode?,
  originalCondition: TaskBoardPolicyPipelineEdgeCondition?
) -> TaskBoardPolicyPipelineEdgeCondition {
  if let sourceNode, policyCanvasNodeExportsBooleanBranches(sourceNode) {
    switch edge.source.portID {
    case "then":
      return TaskBoardPolicyPipelineEdgeCondition(condition: "condition_true")
    case "else":
      return TaskBoardPolicyPipelineEdgeCondition(condition: "condition_false")
    default:
      break
    }
  }
  // The branch's own reason code is the editable source of truth (a merged
  // wire seeds one branch per daemon edge on load; a plain edge has one branch
  // mirroring itself), so reason-code edits - including clearing to nil -
  // round-trip on export. Actions still ride the cache (no actions editor).
  return TaskBoardPolicyPipelineEdgeCondition(
    condition: edge.condition,
    actions: originalCondition?.actions ?? [],
    reasonCode: edge.branches.first?.reasonCode
  )
}

func policyCanvasNodeExportsBooleanBranches(_ node: PolicyCanvasNode) -> Bool {
  (node.policyKind ?? taskBoardPolicyNodeKind(for: node.kind)).kind
    == PolicyCanvasNodeKind.ifThenElse.rawValue
}
