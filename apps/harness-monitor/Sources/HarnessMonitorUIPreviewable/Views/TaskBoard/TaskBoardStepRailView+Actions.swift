import HarnessMonitorKit
import SwiftUI

extension TaskBoardStepRailView {
  func enqueueExternalSync() {
    guard stepRailState.begin(step: 1) else { return }
    let state = stepRailState
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Running task-board external sync") {
        let succeeded = await store.syncTaskBoard(
          request: TaskBoardSyncRequest(direction: .pull, dryRun: false)
        )
        await MainActor.run {
          if succeeded { state.resetFlow() }
          state.finish(step: 1, succeeded: succeeded)
        }
      }
    )
  }

  func enqueueEvaluation(step: Int) {
    guard let item = activeItem, stepRailState.begin(step: step) else { return }
    let state = stepRailState
    let request = TaskBoardOverviewItemBehavior.evaluationRequest(for: item)
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Evaluating task-board item") {
        let succeeded = await store.evaluateTaskBoard(request: request)
        await MainActor.run {
          state.requestApprovalRefresh()
          if succeeded, step == 2 { state.resetFlow() }
          state.finish(step: step, succeeded: succeeded)
        }
      }
    )
  }

  func enqueuePick() {
    guard stepRailState.begin(step: 3) else { return }
    let state = stepRailState
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Picking top task-board item") {
        let selection = await store.pickTaskBoardDispatch()
        await MainActor.run {
          state.requestApprovalRefresh()
          state.pickedSelection = selection
          state.delivery = nil
          state.completedSteps.subtract([4, 5, 6, 7, 8])
          state.finish(step: 3, succeeded: selection != nil)
        }
      }
    )
  }

  func enqueueDelivery() {
    guard
      let selection = stepRailState.pickedSelection,
      stepRailState.begin(step: 4)
    else { return }
    let itemID = selection.item.id
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
          state.finish(step: 4, succeeded: delivery != nil)
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
    stepRailState.completedSteps.insert(5)
  }

  func openReview() {
    guard let item = activeItem else { return }
    if item.hasLinkedSessionTask {
      actions.openTaskBoardItem(item)
    } else if let url = item.taskBoardGitHubURL {
      openURL(url)
    } else {
      return
    }
    stepRailState.completedSteps.insert(7)
  }

  func enqueueCompletion() {
    guard let item = activeItem, stepRailState.begin(step: 8) else { return }
    let state = stepRailState
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Completing task-board item") {
        let succeeded = await store.updateTaskBoardItem(
          id: item.id,
          request: TaskBoardUpdateItemRequest(status: .done),
          successMessage: "Completed task-board item"
        )
        await state.finish(step: 8, succeeded: succeeded)
      }
    )
  }

}
