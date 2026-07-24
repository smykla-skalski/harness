import Foundation

/// Result of a triage-override set or clear under one item-revision and
/// item-list sequence CAS. Mirrors `TaskBoardItemPositionMutationResponse`'s
/// snapshot/shifted shape since both ride the same lane-transition machinery.
public struct TaskBoardTriageOverrideMutationResponse: Equatable, Sendable {
  public let snapshot: TaskBoardItemPositionSnapshot
  public let shifted: [TaskBoardShiftedItemRevision]
  public let triageOverride: TaskBoardTriageOverride?
  public let effective: TaskBoardTriageEffectiveOutcome?

  public init(
    snapshot: TaskBoardItemPositionSnapshot,
    shifted: [TaskBoardShiftedItemRevision],
    triageOverride: TaskBoardTriageOverride?,
    effective: TaskBoardTriageEffectiveOutcome?
  ) {
    self.snapshot = snapshot
    self.shifted = shifted
    self.triageOverride = triageOverride
    self.effective = effective
  }
}
