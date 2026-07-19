import HarnessMonitorKit
import SwiftUI

extension TaskBoardStepRailView {
  func enqueueExternalSync(itemID: String?) {
    guard stepRailState.beginExternalSync(itemID: itemID) else { return }
    let state = stepRailState
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Running task-board external sync") {
        let succeeded = await store.syncTaskBoard(
          request: TaskBoardSyncRequest(direction: .pull, dryRun: false)
        )
        await MainActor.run {
          state.finishExternalSync(succeeded: succeeded)
        }
      }
    )
  }

  func enqueueEvaluation(itemID: String) {
    guard let item = activeItem, item.id == itemID, stepRailState.begin() else { return }
    let state = stepRailState
    state.preserveFlowIdentity(itemID: item.id)
    let request = TaskBoardOverviewItemBehavior.evaluationRequest(for: item)
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Evaluating task-board item") {
        _ = await store.evaluateTaskBoard(request: request)
        await MainActor.run {
          state.requestApprovalRefresh()
          state.finish()
        }
      }
    )
  }

  func enqueuePick() {
    guard stepRailState.begin() else { return }
    let state = stepRailState
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Picking top task-board item") {
        let selection = await store.pickTaskBoardDispatch()
        await MainActor.run {
          state.requestApprovalRefresh()
          state.pickedSelection = selection
          state.delivery = nil
          // Always track the picked item, clearing the lock when Pick returned nil.
          state.lockedItemID = selection?.item.id
          state.finish()
        }
      }
    )
  }

  func enqueueDelivery(itemID: String) {
    guard
      deliveryItemID == itemID,
      stepRailState.begin()
    else { return }
    stepRailState.preserveFlowIdentity(itemID: itemID)
    let isAlreadyHeld = status.heldDispatches.items.contains { $0.boardItemId == itemID }
    let projectDir = status.settings.projectDir
    let state = stepRailState
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Delivering task-board item") {
        let delivery = await store.prepareAndDeliverTaskBoardDispatch(
          request: TaskBoardDispatchRequest(
            itemId: itemID,
            dryRun: false,
            projectDir: projectDir
          ),
          isAlreadyHeld: isAlreadyHeld
        )
        await MainActor.run {
          state.requestApprovalRefresh()
          state.delivery = delivery
          state.finish()
        }
      }
    )
  }

  func openSpawnedAgent() {
    guard
      let item = activeItem,
      let sessionID = stepRailState.delivery?.applied.sessionId ?? item.sessionId
    else { return }
    TaskBoardSpawnedSessionNavigator.open(
      store: store,
      openWindow: openWindow,
      sessionID: sessionID,
      workItemID: stepRailState.delivery?.applied.workItemId ?? item.workItemId,
      managedAgent: stepRailState.delivery?.startedAgent
    )
  }

  func openReview() {
    guard let item = activeItem else { return }
    if item.hasLinkedSessionTask {
      actions.openTaskBoardItem(item)
    } else if let url = item.taskBoardGitHubURL {
      openURL(url)
    }
  }

  func enqueueCompletion(itemID: String) {
    guard let item = activeItem, item.id == itemID, stepRailState.begin() else { return }
    let state = stepRailState
    state.preserveFlowIdentity(itemID: item.id)
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Completing task-board item") {
        let succeeded = await store.updateTaskBoardItem(
          id: item.id,
          request: TaskBoardUpdateItemRequest(status: .done),
          successMessage: "Completed task-board item"
        )
        await MainActor.run {
          if succeeded { state.resetFlow() }
          state.finish()
        }
      }
    )
  }
}
