import HarnessMonitorKit
import SwiftUI
import HarnessMonitorPolicyCanvasAlgorithms

extension PolicyCanvasViewModel {
  /// Apply a branch reason-code edit on a (possibly merged) edge and return its
  /// inverse. Locates the owning edge by `edgeID` and the branch by
  /// `daemonEdgeID`; a missing edge or branch yields an identity inverse so a
  /// stale undo step is a no-op rather than a crash. Reason codes are the
  /// failure-type selector each branch routes on, so this is what lets one
  /// merged wire fan its branches to different reactions on export.
  func applySetBranchReasonCode(
    edgeID: String,
    daemonEdgeID: String,
    from: String?,
    to: String?
  ) -> PolicyCanvasChange {
    guard
      let edgeIndex = edges.firstIndex(where: { $0.id == edgeID }),
      let branchIndex = edges[edgeIndex].branches.firstIndex(
        where: { $0.daemonEdgeID == daemonEdgeID })
    else {
      return .setBranchReasonCode(edgeID: edgeID, daemonEdgeID: daemonEdgeID, from: to, to: to)
    }
    markEdgeEdited(edgeID)
    edges[edgeIndex].branches[branchIndex].reasonCode = to
    return .setBranchReasonCode(edgeID: edgeID, daemonEdgeID: daemonEdgeID, from: to, to: from)
  }

  /// Replace the edges of one fan-in tuple with a new set and return the inverse
  /// (swapped edge sets + selections). Topology branch edits route through here
  /// so a retarget/add/remove lands as one atomic undo step; routing recomputes
  /// from the new edge set, so append order is immaterial.
  func applySetEdgeBranches(
    fromEdges: [PolicyCanvasEdge],
    toEdges: [PolicyCanvasEdge],
    actionName: String,
    priorSelection: PolicyCanvasSelection?,
    restoreSelection: PolicyCanvasSelection?
  ) -> PolicyCanvasChange {
    let removedIDs = Set(fromEdges.map(\.id))
    edges.removeAll { removedIDs.contains($0.id) }
    edges.append(contentsOf: toEdges)
    for edge in toEdges {
      markEdgeEdited(edge.id)
    }
    selection = restoreSelection
    return .setEdgeBranches(
      fromEdges: toEdges,
      toEdges: fromEdges,
      actionName: actionName,
      priorSelection: restoreSelection,
      restoreSelection: priorSelection
    )
  }

  /// Split one branch out of a merged wire and point it at a new target, so a
  /// failure type can route to its own reaction (e.g. send `reviewer_not_approved`
  /// to a human gate while the rest still deny). The branch leaves as its own
  /// plain edge keyed by its daemon id; if the merge drops to a single branch it
  /// demotes back to a plain edge with that branch's daemon id restored, exactly
  /// the id a later re-merge would fold. No-op unless `edgeID` is a merged wire
  /// holding the branch.
  func retargetBranch(
    edgeID: String,
    daemonEdgeID: String,
    to newTarget: PolicyCanvasPortEndpoint
  ) {
    guard
      let edge = edges.first(where: { $0.id == edgeID }),
      edge.isMerged,
      let branch = edge.branches.first(where: { $0.daemonEdgeID == daemonEdgeID }),
      branch.target.nodeID != newTarget.nodeID || branch.target.portID != newTarget.portID
    else {
      return
    }
    let splitEdge = PolicyCanvasEdge(
      id: branch.daemonEdgeID,
      source: edge.source,
      target: newTarget,
      label: branch.label,
      condition: branch.condition,
      pinnedPortSide: edge.pinnedPortSide,
      reasonCode: branch.reasonCode
    )
    let reduced = policyCanvasReducedMergedEdge(
      edge, remaining: edge.branches.filter { $0.daemonEdgeID != daemonEdgeID })
    mutate(
      .setEdgeBranches(
        fromEdges: [edge],
        toEdges: [reduced, splitEdge],
        actionName: "Retarget Branch",
        priorSelection: selection,
        restoreSelection: .edge(splitEdge.id)
      )
    )
  }

  /// Commit a branch reason-code pick from the inspector. No-op when unchanged
  /// so an idle picker render does not push an empty undo step.
  func commitBranchReasonCode(
    edgeID: String,
    daemonEdgeID: String,
    from: String?,
    to: String?
  ) {
    guard from != to else { return }
    mutate(.setBranchReasonCode(edgeID: edgeID, daemonEdgeID: daemonEdgeID, from: from, to: to))
  }

  /// Retarget a branch onto a node's first input port. The inspector target
  /// picker chooses a node; ports are kind-scoped so the first input is the
  /// stable attach point. No-op when the node has no input port.
  func retargetBranch(edgeID: String, daemonEdgeID: String, toNodeID nodeID: String) {
    guard let port = node(nodeID)?.inputPorts.first else { return }
    retargetBranch(
      edgeID: edgeID,
      daemonEdgeID: daemonEdgeID,
      to: PolicyCanvasPortEndpoint(nodeID: nodeID, portID: port.id, kind: .input)
    )
  }

  /// Nodes a branch can retarget onto: any node with an input port other than
  /// the branch's own source node. The inspector target picker lists these in
  /// visual focus order so the choices read top-to-bottom like the canvas.
  func branchRetargetCandidateNodes(excludingSourceNodeID sourceNodeID: String)
    -> [PolicyCanvasNode]
  {
    nodesInFocusOrder.filter { $0.id != sourceNodeID && !$0.inputPorts.isEmpty }
  }

  /// Append a reason-code branch to an edge, folding a plain edge into a merged
  /// wire (or growing an existing merge). The branch starts with no reason code
  /// so the author sets it next; it shares the edge's condition, label, and
  /// target and gets a fresh daemon id so export emits a distinct edge. Selects
  /// the new branch so the inspector highlights the row to fill in.
  func addBranch(toEdgeID edgeID: String) {
    guard let edge = edges.first(where: { $0.id == edgeID }) else { return }
    let branchEdge = PolicyCanvasEdge(
      id: freshDaemonEdgeID(source: edge.source, target: edge.target),
      source: edge.source,
      target: edge.target,
      label: edge.label,
      condition: edge.condition,
      pinnedPortSide: edge.pinnedPortSide,
      reasonCode: nil
    )
    let merged = policyCanvasMergedEdge([edge, branchEdge])
    mutate(
      .setEdgeBranches(
        fromEdges: [edge],
        toEdges: [merged],
        actionName: "Add Branch",
        priorSelection: selection,
        restoreSelection: .edge(merged.id)
      )
    )
    selectedBranchDaemonEdgeID = branchEdge.id
  }

  /// Remove one branch from a merged wire, discarding it. When the merge drops
  /// to a single branch the wire demotes to a plain edge keyed by that branch's
  /// daemon id. No-op unless `edgeID` is a merged wire holding the branch, so the
  /// lone branch of a plain edge can never be removed - delete the edge instead.
  func removeBranch(edgeID: String, daemonEdgeID: String) {
    guard
      let edge = edges.first(where: { $0.id == edgeID }),
      edge.isMerged,
      edge.branches.contains(where: { $0.daemonEdgeID == daemonEdgeID })
    else {
      return
    }
    let reduced = policyCanvasReducedMergedEdge(
      edge, remaining: edge.branches.filter { $0.daemonEdgeID != daemonEdgeID })
    if selectedBranchDaemonEdgeID == daemonEdgeID {
      selectedBranchDaemonEdgeID = nil
    }
    mutate(
      .setEdgeBranches(
        fromEdges: [edge],
        toEdges: [reduced],
        actionName: "Remove Branch",
        priorSelection: selection,
        restoreSelection: .edge(reduced.id)
      )
    )
  }

  /// A daemon edge id unique across every branch, derived from the tuple so it
  /// is deterministic (stable undo, no UUID churn). Falls back to numbered
  /// suffixes when the base id is already taken by an existing branch.
  private func freshDaemonEdgeID(
    source: PolicyCanvasPortEndpoint,
    target: PolicyCanvasPortEndpoint
  ) -> String {
    let base = "edge-\(source.nodeID)-\(source.portID)-\(target.nodeID)-\(target.portID)"
    let taken = Set(edges.flatMap { $0.branches.map(\.daemonEdgeID) })
    guard taken.contains(base) else { return base }
    var suffix = 2
    while taken.contains("\(base)-\(suffix)") { suffix += 1 }
    return "\(base)-\(suffix)"
  }

  /// Rebuild a merged wire after a branch leaves: keep the merged id while two or
  /// more branches remain, or demote to a plain edge keyed by the lone branch's
  /// daemon id so the wire stops claiming to stand for a family of one.
  private func policyCanvasReducedMergedEdge(
    _ edge: PolicyCanvasEdge,
    remaining: [PolicyCanvasEdgeBranch]
  ) -> PolicyCanvasEdge {
    if remaining.count == 1, let only = remaining.first {
      return PolicyCanvasEdge(
        id: only.daemonEdgeID,
        source: edge.source,
        target: only.target,
        label: only.label,
        condition: only.condition,
        pinnedPortSide: edge.pinnedPortSide,
        reasonCode: only.reasonCode
      )
    }
    var rebuilt = edge
    rebuilt.branches = remaining
    return rebuilt
  }
}
