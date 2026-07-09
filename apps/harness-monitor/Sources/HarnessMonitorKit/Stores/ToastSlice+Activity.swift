import Foundation

extension ToastSlice {
  public func activeFeedback(in position: ActionFeedback.Position) -> [ActionFeedback] {
    activeFeedback.filter { $0.position == position }
  }

  @discardableResult
  public func presentActivity(
    key: String,
    message: String,
    title: String? = nil,
    accessibilityIdentifier: String? = nil,
    position: ActionFeedback.Position? = nil
  ) -> UUID {
    updateActivity(
      key: key,
      message: message,
      title: title,
      accessibilityIdentifier: accessibilityIdentifier,
      position: position
    )
  }

  @discardableResult
  public func updateActivity(
    key: String,
    message: String,
    title: String? = nil,
    accessibilityIdentifier: String? = nil,
    position: ActionFeedback.Position? = nil
  ) -> UUID {
    let now = clock.now
    let resolvedAccessibilityIdentifier =
      accessibilityIdentifier ?? "harness.toast.activity.\(key)"
    if let existingID = activityToastIDs[key],
      let existingIndex = activeFeedback.firstIndex(where: { $0.id == existingID })
    {
      let existing = activeFeedback[existingIndex]
      let resolvedPosition = position ?? existing.position
      let feedback = ActionFeedback(
        id: existing.id,
        title: title ?? existing.title,
        message: message,
        severity: .activity,
        details: existing.details,
        primaryAction: existing.primaryAction,
        accessibilityIdentifier: resolvedAccessibilityIdentifier,
        position: resolvedPosition,
        repeatCount: existing.repeatCount,
        issuedAt: now
      )
      replaceActiveFeedback(at: existingIndex, with: feedback)
      enforceMaxVisible(in: resolvedPosition)
      emitHistoryEvent(
        feedback: feedback,
        kind: .refreshed,
        recordedAt: .now,
        hasUndoAction: false
      )
      announce(feedback)
      return existing.id
    }

    let id = present(
      title: title,
      message: message,
      severity: .activity,
      accessibilityIdentifier: resolvedAccessibilityIdentifier,
      rollupDuplicates: false,
      position: position ?? .topTrailing
    )
    activityToastIDs[key] = id
    return id
  }

  public func dismissActivity(key: String) {
    guard let id = activityToastIDs.removeValue(forKey: key) else {
      return
    }
    dismiss(id: id, reason: .manual)
  }
}
