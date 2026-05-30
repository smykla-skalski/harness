import HarnessMonitorKit
import SwiftUI

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
    toEdges.forEach { markEdgeEdited($0.id) }
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
      let branch = edge.branches.first(where: { $0.daemonEdgeID == daemonEdgeID })
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
