import Foundation
import HarnessMonitorKit

/// The Step Mode flow the user was working, kept across app launches. The stage
/// itself is derived from live board and task state, so only the flow's identity
/// needs storing: without it a restart drops back to the first step even though
/// the board is mid-process.
struct TaskBoardStepFlowSnapshot: Codable, Equatable, Sendable {
  var lockedItemID: String
  /// The prompt Pick rendered, so a picked but undelivered item still offers
  /// Deliver with the prompt the user already read. Only the prompt: the rest of
  /// a dispatch plan is readiness, policy, and intent state that the daemon
  /// re-derives, so storing it would bloat preferences with fields that are
  /// stale by the time anything reads them back.
  var pickedPrompt: String?
  /// The picked item's revision. A live item that has moved past it no longer
  /// matches the stored prompt.
  var pickedItemUpdatedAt: String?

  init(
    lockedItemID: String,
    pickedPrompt: String? = nil,
    pickedItemUpdatedAt: String? = nil
  ) {
    self.lockedItemID = lockedItemID
    self.pickedPrompt = pickedPrompt
    self.pickedItemUpdatedAt = pickedItemUpdatedAt
  }
}

@MainActor
enum TaskBoardStepFlowStore {
  static let storageKey = "harness.task-board.step-flow.v1"
  private static let decoder = JSONDecoder()
  private static let encoder = JSONEncoder()

  static func load(from userDefaults: UserDefaults = .standard) -> TaskBoardStepFlowSnapshot? {
    guard let data = userDefaults.data(forKey: storageKey) else { return nil }
    return try? decoder.decode(TaskBoardStepFlowSnapshot.self, from: data)
  }

  /// Saving `nil` forgets the stored flow, so ending one and never starting one
  /// take the same path.
  static func save(
    _ snapshot: TaskBoardStepFlowSnapshot?,
    in userDefaults: UserDefaults = .standard
  ) {
    guard let snapshot, let data = try? encoder.encode(snapshot) else {
      userDefaults.removeObject(forKey: storageKey)
      return
    }
    userDefaults.set(data, forKey: storageKey)
  }
}

struct TaskBoardStepRestoredFlow: Equatable, Sendable {
  let itemID: String
  let pickedPrompt: String?
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
      pickedPrompt: pickedPrompt(for: item, snapshot: snapshot)
    )
  }

  /// The stored prompt only survives while it still describes the live item.
  /// An edited item would otherwise show the old prompt next to a Deliver that
  /// dispatches the daemon's freshly rendered one.
  private static func pickedPrompt(
    for item: TaskBoardItem,
    snapshot: TaskBoardStepFlowSnapshot
  ) -> String? {
    guard snapshot.pickedItemUpdatedAt == item.updatedAt else { return nil }
    return snapshot.pickedPrompt
  }
}
