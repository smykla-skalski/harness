extension TaskBoardItem {
  /// Mirrors the daemon's `triage_eligible`. Dispatch reservation is
  /// server-only and not checked here; a mutation still fails closed there.
  public var isTriageOverrideEligible: Bool {
    kind == .task
      && deletedAt == nil
      && workItemId == nil
      && (status.canonicalPersistedStatus == .backlog || status.canonicalPersistedStatus == .todo)
  }
}
