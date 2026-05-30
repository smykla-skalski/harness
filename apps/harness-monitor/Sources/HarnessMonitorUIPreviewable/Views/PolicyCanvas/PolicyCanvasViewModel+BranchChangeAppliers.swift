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
}
