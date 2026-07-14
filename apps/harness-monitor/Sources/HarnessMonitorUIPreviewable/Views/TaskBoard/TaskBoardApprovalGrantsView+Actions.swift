import HarnessMonitorKit

extension TaskBoardApprovalGrantsView {
  func enqueueRefresh() {
    let state = state
    guard let generation = state.requestRefresh() else { return }
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Loading policy approval grants") {
        var activeGeneration: UInt64? = generation
        while let refreshGeneration = activeGeneration {
          let grants = await store.policyApprovalGrants()
          activeGeneration = await MainActor.run {
            state.completeRefresh(
              generation: refreshGeneration,
              grants: grants
            )
          }
        }
      }
    )
  }

  func enqueueApproval(grantID: String) {
    enqueueResolution(grantID: grantID, approve: true)
  }

  func enqueueRejection(grantID: String) {
    enqueueResolution(grantID: grantID, approve: false)
  }

  private func enqueueResolution(grantID: String, approve: Bool) {
    guard state.activeGrantID == nil else { return }
    state.activeGrantID = grantID
    let state = state
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: approve ? "Approving policy grant" : "Rejecting policy grant") {
        let grant = await store.resolvePolicyApprovalGrant(
          grantID: grantID,
          approve: approve
        )
        await MainActor.run {
          if let grant {
            state.apply(grant)
          }
          state.activeGrantID = nil
        }
      }
    )
  }

  func enqueueRevocation(grantID: String) {
    guard state.activeGrantID == nil else { return }
    state.activeGrantID = grantID
    let state = state
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Revoking policy grant") {
        let grant = await store.revokePolicyApprovalGrant(grantID: grantID)
        await MainActor.run {
          if let grant {
            state.apply(grant)
          }
          state.activeGrantID = nil
        }
      }
    )
  }
}
