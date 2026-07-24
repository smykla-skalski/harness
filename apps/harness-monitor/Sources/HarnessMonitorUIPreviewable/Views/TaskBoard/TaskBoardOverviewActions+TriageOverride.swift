import HarnessMonitorKit

extension TaskBoardOverviewActions {
  @MainActor
  var canMutateTaskBoardTriageOverride: Bool {
    guard let store else { return false }
    guard let profile = store.remoteDaemonProfile else { return true }
    return profile.status == .active
      && profile.role != .viewer
      && profile.scopes.contains("write")
  }

  @MainActor
  func setTaskBoardTriageOverride(
    _ item: TaskBoardItem,
    verdict: TriageVerdict,
    reason: String?,
    refreshing state: TaskBoardTriageInspectorState
  ) {
    guard let store, canMutateTaskBoardTriageOverride else { return }
    let fenceToken = state.beginMutation(itemID: item.id)
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Setting triage override") {
        let succeeded = await store.setTaskBoardItemTriageOverride(
          id: item.id, verdict: verdict, reason: reason)
        let updatedAt = await MainActor.run {
          succeeded
            ? store.globalTaskBoardItems.first(where: { $0.id == item.id })?.updatedAt
            : nil
        }
        let refreshed = await store.taskBoardItemTriageCurrent(id: item.id)
        await state.receive(
          refreshed,
          itemID: item.id,
          itemUpdatedAt: updatedAt,
          token: fenceToken
        )
      }
    )
  }

  @MainActor
  func clearTaskBoardTriageOverride(
    _ item: TaskBoardItem,
    refreshing state: TaskBoardTriageInspectorState
  ) {
    guard let store, canMutateTaskBoardTriageOverride else { return }
    let fenceToken = state.beginMutation(itemID: item.id)
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Clearing triage override") {
        let succeeded = await store.clearTaskBoardItemTriageOverride(id: item.id)
        let updatedAt = await MainActor.run {
          succeeded
            ? store.globalTaskBoardItems.first(where: { $0.id == item.id })?.updatedAt
            : nil
        }
        let refreshed = await store.taskBoardItemTriageCurrent(id: item.id)
        await state.receive(
          refreshed,
          itemID: item.id,
          itemUpdatedAt: updatedAt,
          token: fenceToken
        )
      }
    )
  }
}
