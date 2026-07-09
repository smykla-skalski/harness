import AppKit
import Foundation

extension ToastSlice {
  func rearmDismissIfNeeded(
    for id: UUID,
    severity: ActionFeedback.Severity,
    from now: ContinuousClock.Instant
  ) {
    guard severity != .activity else {
      dismissTasks[id]?.cancel()
      dismissTasks.removeValue(forKey: id)
      targetInstants.removeValue(forKey: id)
      return
    }
    rearmDismiss(for: id, severity: severity, from: now)
  }

  func dismissDelay(for severity: ActionFeedback.Severity) -> Duration {
    switch severity {
    case .activity: .seconds(0)
    case .success: successDismissDelay
    case .warning: warningDismissDelay
    case .failure: failureDismissDelay
    case .undoable: undoableDismissDelay
    }
  }

  func announce(_ feedback: ActionFeedback) {
    let prefix: String
    switch feedback.severity {
    case .activity: prefix = "In progress"
    case .success: prefix = "Success"
    case .warning: prefix = "Warning"
    case .failure: prefix = "Action failed"
    case .undoable: prefix = "Started"
    }
    let repetitionNotice =
      if feedback.repeatCount > 1 {
        " Repeated \(feedback.repeatCount) times"
      } else {
        ""
      }
    let payload = AttributedString("\(prefix) \(feedback.announcementText)\(repetitionNotice)")
    AccessibilityNotification.Announcement(payload).post()
  }

  func emitHistoryEvent(
    feedback: ActionFeedback,
    kind: ToastHistoryEvent.Kind,
    recordedAt: Date,
    hasUndoAction: Bool
  ) {
    onHistoryEvent?(
      ToastHistoryEvent(
        feedback: feedback,
        recordedAt: recordedAt,
        kind: kind,
        hasUndoAction: hasUndoAction
      ))
  }
}
