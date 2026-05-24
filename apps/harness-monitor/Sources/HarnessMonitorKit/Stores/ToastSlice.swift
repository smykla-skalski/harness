import AppKit
import Foundation
import Observation

public protocol ContinuousClockSource: AnyObject, Sendable {
  @MainActor var now: ContinuousClock.Instant { get }
}

public final class LiveContinuousClockSource: ContinuousClockSource, @unchecked Sendable {
  public init() {}
  @MainActor public var now: ContinuousClock.Instant { ContinuousClock.now }
}

@MainActor
@Observable
public final class ToastSlice {
  public private(set) var activeFeedback: [ActionFeedback] = [] {
    didSet {
      onChanged?()
    }
  }
  public var maxVisible: Int = 3
  public var successDismissDelay: Duration = .seconds(4)
  public var warningDismissDelay: Duration = .seconds(12)
  public var failureDismissDelay: Duration = .seconds(8)
  public var undoableDismissDelay: Duration = .seconds(8)
  public var dedupeWindow: Duration = .seconds(2)

  @ObservationIgnored var dismissTasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored var targetInstants: [UUID: ContinuousClock.Instant] = [:]
  @ObservationIgnored var pendingUndoActions: [UUID: @MainActor () async -> Void] = [:]
  @ObservationIgnored var pauseObservationTask: Task<Void, Never>?
  @ObservationIgnored var resumeObservationTask: Task<Void, Never>?
  @ObservationIgnored let clock: any ContinuousClockSource
  @ObservationIgnored public var onChanged: (() -> Void)?
  @ObservationIgnored public var onHistoryEvent: ((ToastHistoryEvent) -> Void)?

  public init(clock: any ContinuousClockSource = LiveContinuousClockSource()) {
    self.clock = clock
  }

  deinit {
    for task in dismissTasks.values {
      task.cancel()
    }
    pauseObservationTask?.cancel()
    resumeObservationTask?.cancel()
  }

  public var pendingDismissCount: Int {
    dismissTasks.count
  }

  // MARK: - Public API

  @discardableResult
  public func presentSuccess(
    _ message: String,
    title: String? = nil,
    details: ActionFeedbackDetails? = nil,
    primaryAction: ActionFeedbackAction? = nil,
    accessibilityIdentifier: String? = nil,
    rollupDuplicates: Bool = false
  ) -> UUID {
    present(
      title: title,
      message: message,
      severity: .success,
      details: details,
      primaryAction: primaryAction,
      accessibilityIdentifier: accessibilityIdentifier,
      rollupDuplicates: rollupDuplicates
    )
  }

  @discardableResult
  public func presentFailure(
    _ message: String,
    title: String? = nil,
    details: ActionFeedbackDetails? = nil,
    primaryAction: ActionFeedbackAction? = nil,
    accessibilityIdentifier: String? = nil,
    rollupDuplicates: Bool = false
  ) -> UUID {
    present(
      title: title,
      message: message,
      severity: .failure,
      details: details,
      primaryAction: primaryAction,
      accessibilityIdentifier: accessibilityIdentifier,
      rollupDuplicates: rollupDuplicates
    )
  }

  @discardableResult
  public func presentWarning(
    _ message: String,
    title: String? = nil,
    details: ActionFeedbackDetails? = nil,
    primaryAction: ActionFeedbackAction? = nil,
    accessibilityIdentifier: String? = nil,
    rollupDuplicates: Bool = false
  ) -> UUID {
    present(
      title: title,
      message: message,
      severity: .warning,
      details: details,
      primaryAction: primaryAction,
      accessibilityIdentifier: accessibilityIdentifier,
      rollupDuplicates: rollupDuplicates
    )
  }

  @discardableResult
  public func present(message: String, severity: ActionFeedback.Severity) -> UUID {
    present(
      title: nil,
      message: message,
      severity: severity,
      details: nil,
      primaryAction: nil,
      accessibilityIdentifier: nil,
      rollupDuplicates: false
    )
  }

  @discardableResult
  public func enqueueUndoable(
    _ message: String,
    accessibilityIdentifier: String? = nil,
    undo: @escaping @MainActor () async -> Void
  ) -> UUID {
    present(
      title: nil,
      message: message,
      severity: .undoable,
      details: nil,
      primaryAction: nil,
      accessibilityIdentifier: accessibilityIdentifier,
      rollupDuplicates: false,
      undoAction: undo
    )
  }

  public func invokeUndo(id: UUID) {
    guard let action = pendingUndoActions.removeValue(forKey: id) else {
      return
    }
    dismiss(id: id, reason: .undoInvoked)
    Task { @MainActor in
      await action()
    }
  }

  public func hasUndoAction(id: UUID) -> Bool {
    pendingUndoActions[id] != nil
  }

  @discardableResult
  public func present(
    title: String? = nil,
    message: String,
    severity: ActionFeedback.Severity,
    details: ActionFeedbackDetails? = nil,
    primaryAction: ActionFeedbackAction? = nil,
    accessibilityIdentifier: String?,
    rollupDuplicates: Bool = false,
    undoAction: (@MainActor () async -> Void)? = nil
  ) -> UUID {
    let now = clock.now
    let window = dedupeWindow
    let existingIndex = activeFeedback.firstIndex { feedback -> Bool in
      guard feedback.severity == severity,
        feedback.title == title,
        feedback.message == message,
        feedback.details == details,
        feedback.primaryAction == primaryAction,
        feedback.accessibilityIdentifier == accessibilityIdentifier
      else {
        return false
      }
      let elapsed: Duration = now - feedback.issuedAt
      return elapsed < window
    }
    if let existingIndex {
      let existing = activeFeedback[existingIndex]
      var refreshed = existing
      if rollupDuplicates {
        refreshed.repeatCount += 1
      }
      refreshed.issuedAt = now
      refreshed.pausedRemaining = nil
      activeFeedback[existingIndex] = refreshed
      if let undoAction {
        pendingUndoActions[existing.id] = undoAction
      }
      rearmDismiss(for: existing.id, severity: severity, from: now)
      emitHistoryEvent(
        feedback: refreshed,
        kind: .refreshed,
        recordedAt: .now,
        hasUndoAction: pendingUndoActions[existing.id] != nil
      )
      announce(refreshed)
      return existing.id
    }

    let feedback = ActionFeedback(
      title: title,
      message: message,
      severity: severity,
      details: details,
      primaryAction: primaryAction,
      accessibilityIdentifier: accessibilityIdentifier,
      issuedAt: now
    )
    activeFeedback.insert(feedback, at: 0)
    if let undoAction {
      pendingUndoActions[feedback.id] = undoAction
    }
    rearmDismiss(for: feedback.id, severity: severity, from: now)
    enforceMaxVisible()
    emitHistoryEvent(
      feedback: feedback,
      kind: .presented,
      recordedAt: .now,
      hasUndoAction: pendingUndoActions[feedback.id] != nil
    )
    announce(feedback)
    return feedback.id
  }

  public func dismiss(id: UUID) {
    dismiss(id: id, reason: .manual)
  }

  public func dismissAll() {
    for feedback in activeFeedback {
      dismiss(id: feedback.id, reason: .manual)
    }
  }

  public func dismissAllMatching(severity: ActionFeedback.Severity) {
    let matching = activeFeedback.filter { $0.severity == severity }
    for feedback in matching {
      dismiss(id: feedback.id, reason: .manual)
    }
  }

  func dismiss(id: UUID, reason: ToastHistoryEvent.DismissReason) {
    let dismissedFeedback = activeFeedback.first { $0.id == id }
    dismissTasks[id]?.cancel()
    dismissTasks.removeValue(forKey: id)
    targetInstants.removeValue(forKey: id)
    pendingUndoActions.removeValue(forKey: id)
    activeFeedback.removeAll { $0.id == id }
    if let dismissedFeedback {
      emitHistoryEvent(
        feedback: dismissedFeedback,
        kind: .dismissed(reason),
        recordedAt: .now,
        hasUndoAction: false
      )
    }
  }

  public func pauseTimers() {
    let now = clock.now
    for index in activeFeedback.indices {
      let feedback = activeFeedback[index]
      guard feedback.pausedRemaining == nil,
        let target = targetInstants[feedback.id]
      else {
        continue
      }
      let remaining = max(.zero, target - now)
      var paused = feedback
      paused.pausedRemaining = remaining
      activeFeedback[index] = paused

      dismissTasks[feedback.id]?.cancel()
      dismissTasks.removeValue(forKey: feedback.id)
    }
  }

  public func resumeTimers() {
    let now = clock.now
    for index in activeFeedback.indices {
      let feedback = activeFeedback[index]
      guard let remaining = feedback.pausedRemaining else {
        continue
      }
      var resumed = feedback
      resumed.pausedRemaining = nil
      resumed.issuedAt = now
      activeFeedback[index] = resumed

      let target = now.advanced(by: remaining)
      targetInstants[feedback.id] = target
      scheduleDismiss(for: feedback.id, after: remaining)
    }
  }

  /// Test helper: dismiss every toast whose virtual target instant has elapsed
  /// according to the injected clock. Cancels and removes any in-flight real
  /// dismiss tasks for matured toasts. Toasts whose timers are paused are
  /// skipped.
  public func flushPendingDismissals() async {
    let now = clock.now
    let matured = activeFeedback.filter { feedback in
      guard feedback.pausedRemaining == nil else { return false }
      guard let target = targetInstants[feedback.id] else { return false }
      return target <= now
    }
    for feedback in matured {
      dismiss(id: feedback.id, reason: .timedOut)
    }
    await Task.yield()
  }

  // MARK: - Private helpers

  func enforceMaxVisible() {
    while activeFeedback.count > maxVisible {
      guard let oldest = activeFeedback.last else { break }
      dismiss(id: oldest.id, reason: .evicted)
    }
  }

  func rearmDismiss(
    for id: UUID,
    severity: ActionFeedback.Severity,
    from now: ContinuousClock.Instant
  ) {
    let delay = dismissDelay(for: severity)
    targetInstants[id] = now.advanced(by: delay)
    scheduleDismiss(for: id, after: delay)
  }

  func scheduleDismiss(for id: UUID, after delay: Duration) {
    dismissTasks[id]?.cancel()
    dismissTasks[id] = Task { @MainActor [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, let self else { return }
      self.dismiss(id: id, reason: .timedOut)
    }
  }

  func dismissDelay(for severity: ActionFeedback.Severity) -> Duration {
    switch severity {
    case .success: successDismissDelay
    case .warning: warningDismissDelay
    case .failure: failureDismissDelay
    case .undoable: undoableDismissDelay
    }
  }

  func announce(_ feedback: ActionFeedback) {
    let prefix: String
    switch feedback.severity {
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
