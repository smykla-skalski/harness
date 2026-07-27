import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("Step Mode flow persistence")
final class TaskBoardStepFlowPersistenceTests {
  /// One throwaway defaults domain per test, dropped when the suite instance
  /// goes away, so a stored flow never reaches the app's real preferences.
  let suiteName = "io.harnessmonitor.tests.step-flow.\(UUID().uuidString)"
  lazy var defaults = UserDefaults(suiteName: suiteName) ?? .standard

  deinit {
    UserDefaults().removePersistentDomain(forName: suiteName)
  }

  @Test("A saved flow survives a reload")
  func savedFlowSurvivesReload() {
    let target = item(id: "active", status: .todo)
    let snapshot = TaskBoardStepFlowSnapshot(
      lockedItemID: target.id,
      pickedPlan: dispatchPlan(for: target),
      pickedItemUpdatedAt: target.updatedAt
    )

    TaskBoardStepFlowStore.save(snapshot, in: defaults)

    #expect(TaskBoardStepFlowStore.load(from: defaults) == snapshot)
  }

  @Test("Saving nothing forgets the stored flow")
  func savingNothingForgetsStoredFlow() {
    TaskBoardStepFlowStore.save(
      TaskBoardStepFlowSnapshot(lockedItemID: "active"),
      in: defaults
    )

    TaskBoardStepFlowStore.save(nil, in: defaults)

    #expect(TaskBoardStepFlowStore.load(from: defaults) == nil)
  }

  @Test("A stored flow resumes on the live item it pinned")
  func storedFlowResumesOnLiveItem() {
    let target = item(id: "active", status: .todo)
    let restored = TaskBoardStepFlowRestoration.restoredFlow(
      snapshot: TaskBoardStepFlowSnapshot(
        lockedItemID: target.id,
        pickedPlan: dispatchPlan(for: target),
        pickedItemUpdatedAt: target.updatedAt
      ),
      items: [item(id: "other", status: .todo), target]
    )

    #expect(restored?.itemID == target.id)
    #expect(restored?.pickedSelection?.item == target)
    #expect(restored?.pickedSelection?.plan.renderedPrompt == "durable prompt")
  }

  @Test("A prompt the item has moved past is dropped, its flow kept")
  func stalePromptIsDropped() {
    let picked = item(id: "active", status: .todo, updatedAt: "2026-07-19T12:00:00Z")
    let live = item(id: "active", status: .todo, updatedAt: "2026-07-19T12:30:00Z")
    let restored = TaskBoardStepFlowRestoration.restoredFlow(
      snapshot: TaskBoardStepFlowSnapshot(
        lockedItemID: picked.id,
        pickedPlan: dispatchPlan(for: picked),
        pickedItemUpdatedAt: picked.updatedAt
      ),
      items: [live]
    )

    #expect(restored?.itemID == live.id)
    #expect(restored?.pickedSelection == nil)
  }

  @Test("A flow the board has not produced yet stays pending")
  func flowForUnloadedBoardStaysPending() {
    let restored = TaskBoardStepFlowRestoration.restoredFlow(
      snapshot: TaskBoardStepFlowSnapshot(lockedItemID: "active"),
      items: []
    )

    #expect(restored == nil)
  }

  @Test("A deleted item never resumes its flow")
  func deletedItemNeverResumes() {
    let deleted = item(id: "active", status: .todo, deletedAt: "2026-07-19T12:30:00Z")
    let restored = TaskBoardStepFlowRestoration.restoredFlow(
      snapshot: TaskBoardStepFlowSnapshot(lockedItemID: deleted.id),
      items: [deleted]
    )

    #expect(restored == nil)
  }

  @Test("A restarted rail resumes the stored step instead of the first one")
  func restartedRailResumesStoredStep() async {
    let target = item(id: "active", status: .todo)
    TaskBoardStepFlowStore.save(
      TaskBoardStepFlowSnapshot(
        lockedItemID: target.id,
        pickedPlan: dispatchPlan(for: target),
        pickedItemUpdatedAt: target.updatedAt
      ),
      in: defaults
    )
    let view = await railView(targetItem: target, taskBoardItems: [target])
    #expect(view.stagePlan.stage == .readyToPick)

    view.restoreStepFlowIfNeeded()

    #expect(view.stepRailState.lockedItemID == target.id)
    #expect(view.stagePlan.stage == .readyToDeliver)
    #expect(view.stagePlan.primaryAction == .deliver)
    #expect(view.activeSelection?.plan.renderedPrompt == "durable prompt")
  }

  @Test("A flow the user already started outranks the stored one")
  func liveFlowOutranksStoredFlow() async {
    let stored = item(id: "active", status: .todo)
    let other = item(id: "other", status: .todo)
    TaskBoardStepFlowStore.save(
      TaskBoardStepFlowSnapshot(lockedItemID: stored.id),
      in: defaults
    )
    let view = await railView(targetItem: stored, taskBoardItems: [stored, other])

    view.stepRailState.applyPick(
      TaskBoardDispatchSelection(item: other, plan: dispatchPlan(for: other))
    )
    view.restoreStepFlowIfNeeded()

    #expect(view.stepRailState.lockedItemID == other.id)
    #expect(view.stepRailState.pendingRestoredFlow == nil)
  }

  @Test("Restoring a flow does not rewrite what is stored")
  func restoringDoesNotRewriteStoredFlow() async {
    let picked = item(id: "active", status: .todo, updatedAt: "2026-07-19T12:00:00Z")
    let live = item(id: "active", status: .todo, updatedAt: "2026-07-19T12:30:00Z")
    let snapshot = TaskBoardStepFlowSnapshot(
      lockedItemID: picked.id,
      pickedPlan: dispatchPlan(for: picked),
      pickedItemUpdatedAt: picked.updatedAt
    )
    TaskBoardStepFlowStore.save(snapshot, in: defaults)
    let view = await railView(targetItem: live, taskBoardItems: [live])
    let revisionBeforeRestore = view.stepRailState.flowRevision

    view.restoreStepFlowIfNeeded()

    #expect(view.stepRailState.lockedItemID == live.id)
    #expect(view.stepRailState.flowRevision == revisionBeforeRestore)
    #expect(TaskBoardStepFlowStore.load(from: defaults) == snapshot)
  }

  @Test("Picking an item stores it for the next launch")
  func pickingStoresFlow() async {
    let target = item(id: "active", status: .todo)
    let view = await railView(targetItem: target, taskBoardItems: [target])
    let revisionBeforePick = view.stepRailState.flowRevision

    view.stepRailState.applyPick(
      TaskBoardDispatchSelection(item: target, plan: dispatchPlan(for: target))
    )
    #expect(view.stepRailState.flowRevision == revisionBeforePick &+ 1)
    view.persistStepFlow()

    let stored = TaskBoardStepFlowStore.load(from: defaults)
    #expect(stored?.lockedItemID == target.id)
    #expect(stored?.pickedPlan?.renderedPrompt == "durable prompt")
    #expect(stored?.pickedItemUpdatedAt == target.updatedAt)
  }

  @Test("Pinning a target before Pick stores it too")
  func pinningTargetStoresFlow() async {
    let target = item(id: "active", status: .todo)
    let view = await railView(targetItem: target, taskBoardItems: [target])

    view.stepRailState.preserveFlowIdentity(itemID: target.id)
    view.persistStepFlow()

    let stored = TaskBoardStepFlowStore.load(from: defaults)
    #expect(stored?.lockedItemID == target.id)
    #expect(stored?.pickedPlan == nil)
  }

  @Test("Ending the flow forgets the stored step")
  func endingFlowForgetsStoredStep() async {
    let target = item(id: "active", status: .todo)
    TaskBoardStepFlowStore.save(
      TaskBoardStepFlowSnapshot(lockedItemID: target.id),
      in: defaults
    )
    let view = await railView(targetItem: target, taskBoardItems: [target])
    view.restoreStepFlowIfNeeded()

    view.stepRailState.resetFlow()
    view.persistStepFlow()

    #expect(TaskBoardStepFlowStore.load(from: defaults) == nil)
  }

  @Test("Leaving step mode forgets the stored step")
  func leavingStepModeForgetsStoredStep() async {
    let target = item(id: "active", status: .todo)
    TaskBoardStepFlowStore.save(
      TaskBoardStepFlowSnapshot(lockedItemID: target.id),
      in: defaults
    )
    let view = await railView(targetItem: target, taskBoardItems: [target])
    view.restoreStepFlowIfNeeded()

    view.endStepFlow()

    #expect(view.stepRailState.lockedItemID == nil)
    #expect(TaskBoardStepFlowStore.load(from: defaults) == nil)
  }
}
