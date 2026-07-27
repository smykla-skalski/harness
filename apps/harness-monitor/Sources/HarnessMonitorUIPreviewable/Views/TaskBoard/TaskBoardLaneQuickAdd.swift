import HarnessMonitorKit

extension TaskBoardInboxLane {
  /// A lane takes a typed-in task when it stands for a workflow status the item
  /// can be created in. Umbrella is the one that cannot: it holds a different
  /// kind of item, and a title on its own does not make one.
  var acceptsQuickAddedTask: Bool {
    taskBoardDropStatus != nil
  }
}

enum TaskBoardLaneQuickAdd {
  /// `nil` when there is nothing to create: a title of only whitespace, or a
  /// lane no typed-in task belongs in.
  static func request(title: String, lane: TaskBoardInboxLane) -> TaskBoardCreateItemRequest? {
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty, let status = lane.taskBoardDropStatus else {
      return nil
    }
    // Naming the status is what keeps the item where it was typed: the daemon
    // suppresses automatic triage placement for a create that asked for one.
    return TaskBoardCreateItemRequest(title: title, status: status)
  }

  /// What the field should hold after a create failed. The field is cleared the
  /// moment someone submits, so the text has to come back from somewhere - but
  /// only into a field they have not already started retyping, because the
  /// failure is reported by a toast either way and silently overwriting a second
  /// title loses more than it saves.
  static func restoredTitle(current: String, afterFailed failed: String?) -> String? {
    guard let failed, !failed.isEmpty, current.isBlank else { return nil }
    return failed
  }
}
