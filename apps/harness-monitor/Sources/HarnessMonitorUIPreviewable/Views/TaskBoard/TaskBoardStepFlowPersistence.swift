import Foundation
import HarnessMonitorKit

/// The Step Mode flow the user was working, kept across app launches. The stage
/// itself is derived from live board and task state, so only the flow's identity
/// needs storing: without it a restart drops back to the first step even though
/// the board is mid-process.
struct TaskBoardStepFlowSnapshot: Codable, Equatable, Sendable {
  var lockedItemID: String
  /// The plan Pick loaded, so a picked but undelivered item still offers Deliver
  /// with the prompt the user already read.
  var pickedPlan: TaskBoardDispatchPlan?
  /// The picked item's revision. A live item that has moved past it no longer
  /// matches the stored prompt.
  var pickedItemUpdatedAt: String?

  init(
    lockedItemID: String,
    pickedPlan: TaskBoardDispatchPlan? = nil,
    pickedItemUpdatedAt: String? = nil
  ) {
    self.lockedItemID = lockedItemID
    self.pickedPlan = pickedPlan
    self.pickedItemUpdatedAt = pickedItemUpdatedAt
  }
}

enum TaskBoardStepFlowStore {
  static let storageKey = "harness.task-board.step-flow.v1"

  static func load(from userDefaults: UserDefaults = .standard) -> TaskBoardStepFlowSnapshot? {
    guard let data = userDefaults.data(forKey: storageKey) else { return nil }
    return try? JSONDecoder().decode(TaskBoardStepFlowSnapshot.self, from: data)
  }

  /// Saving `nil` forgets the stored flow, so ending one and never starting one
  /// take the same path.
  static func save(
    _ snapshot: TaskBoardStepFlowSnapshot?,
    in userDefaults: UserDefaults = .standard
  ) {
    guard let snapshot, let data = try? JSONEncoder().encode(snapshot) else {
      userDefaults.removeObject(forKey: storageKey)
      return
    }
    userDefaults.set(data, forKey: storageKey)
  }
}

struct TaskBoardStepRestoredFlow: Equatable, Sendable {
  let itemID: String
  let pickedSelection: TaskBoardDispatchSelection?
}

enum TaskBoardStepFlowRestoration {
  /// The stored flow as the live board sees it, or nil while the board has not
  /// produced that item. Nil is deliberately not a verdict that the item is
  /// gone: the board arrives after the panel mounts, and the stored flow is only
  /// ever replaced by the next flow the user starts.
  static func restoredFlow(
    snapshot: TaskBoardStepFlowSnapshot?,
    items: [TaskBoardItem]
  ) -> TaskBoardStepRestoredFlow? {
    guard
      let snapshot,
      let item = items.first(where: { $0.id == snapshot.lockedItemID && $0.deletedAt == nil })
    else {
      return nil
    }
    return TaskBoardStepRestoredFlow(
      itemID: item.id,
      pickedSelection: pickedSelection(for: item, snapshot: snapshot)
    )
  }

  /// The stored prompt only survives while it still describes the live item.
  /// An edited item would otherwise show the old prompt next to a Deliver that
  /// dispatches the daemon's freshly rendered one.
  private static func pickedSelection(
    for item: TaskBoardItem,
    snapshot: TaskBoardStepFlowSnapshot
  ) -> TaskBoardDispatchSelection? {
    guard
      let plan = snapshot.pickedPlan,
      plan.boardItemId == item.id,
      snapshot.pickedItemUpdatedAt == item.updatedAt
    else {
      return nil
    }
    return TaskBoardDispatchSelection(item: item, plan: plan)
  }
}
