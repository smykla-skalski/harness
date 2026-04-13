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
  public var failureDismissDelay: Duration = .seconds(8)
  public var dedupeWindow: Duration = .seconds(2)

  @ObservationIgnored private var dismissTasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var targetInstants: [UUID: ContinuousClock.Instant] = [:]
  @ObservationIgnored private var pauseObservationTask: Task<Void, Never>?
  @ObservationIgnored private var resumeObservationTask: Task<Void, Never>?
  @ObservationIgnored private let clock: any ContinuousClockSource
  @ObservationIgnored public var onChanged: (() -> Void)?

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
  public func presentSuccess(_ message: String) -> UUID {
    present(message: message, severity: .success)
  }

  @discardableResult
  public func presentFailure(_ message: String) -> UUID {
    present(message: message, severity: .failure)
  }

  @discardableResult
  public func present(message: String, severity: ActionFeedback.Severity) -> UUID {
    let now = clock.now
    let window = dedupeWindow
    let existingIndex = activeFeedback.firstIndex { feedback -> Bool in
      guard feedback.severity == severity, feedback.message == message else {
        return false
      }
      let elapsed: Duration = now - feedback.issuedAt
      return elapsed < window
    }
    if let existingIndex {
      let existing = activeFeedback[existingIndex]
      var refreshed = existing
      refreshed.issuedAt = now
      refreshed.pausedRemaining = nil
      activeFeedback[existingIndex] = refreshed
      rearmDismiss(for: existing.id, severity: severity, from: now)
      announce(refreshed)
      return existing.id
    }

    let feedback = ActionFeedback(
      message: message,
      severity: severity,
      issuedAt: now
    )
    activeFeedback.insert(feedback, at: 0)
    rearmDismiss(for: feedback.id, severity: severity, from: now)
    enforceMaxVisible()
    announce(feedback)
    return feedback.id
  }

  public func dismiss(id: UUID) {
    dismissTasks[id]?.cancel()
    dismissTasks.removeValue(forKey: id)
    targetInstants.removeValue(forKey: id)
    activeFeedback.removeAll { $0.id == id }
  }

  public func dismissAll() {
    for task in dismissTasks.values {
      task.cancel()
    }
    dismissTasks.removeAll()
    targetInstants.removeAll()
    activeFeedback.removeAll()
  }

  public func dismissAllMatching(severity: ActionFeedback.Severity) {
    let matching = activeFeedback.filter { $0.severity == severity }
    for feedback in matching {
      dismiss(id: feedback.id)
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

  public func startObservingAppActivation() {
    guard pauseObservationTask == nil, resumeObservationTask == nil else { return }
    pauseObservationTask = Task { @MainActor [weak self] in
      let stream = NotificationCenter.default.notifications(
        named: NSApplication.didResignActiveNotification
      )
      for await _ in stream {
        guard let self else { return }
        self.pauseTimers()
      }
    }
    resumeObservationTask = Task { @MainActor [weak self] in
      let stream = NotificationCenter.default.notifications(
        named: NSApplication.didBecomeActiveNotification
      )
      for await _ in stream {
        guard let self else { return }
        self.resumeTimers()
      }
    }
  }

  public func stopObservingAppActivation() {
    pauseObservationTask?.cancel()
    resumeObservationTask?.cancel()
    pauseObservationTask = nil
    resumeObservationTask = nil
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
      dismiss(id: feedback.id)
    }
    await Task.yield()
  }

  // MARK: - Private helpers

  private func enforceMaxVisible() {
    while activeFeedback.count > maxVisible {
      guard let oldest = activeFeedback.last else { break }
      dismiss(id: oldest.id)
    }
  }

  private func rearmDismiss(
    for id: UUID,
    severity: ActionFeedback.Severity,
    from now: ContinuousClock.Instant
  ) {
    let delay = dismissDelay(for: severity)
    targetInstants[id] = now.advanced(by: delay)
    scheduleDismiss(for: id, after: delay)
  }

  private func scheduleDismiss(for id: UUID, after delay: Duration) {
    dismissTasks[id]?.cancel()
    dismissTasks[id] = Task { @MainActor [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, let self else { return }
      self.dismiss(id: id)
    }
  }

  private func dismissDelay(for severity: ActionFeedback.Severity) -> Duration {
    switch severity {
    case .success: successDismissDelay
    case .failure: failureDismissDelay
    }
  }

  private func announce(_ feedback: ActionFeedback) {
    let prefix: String
    switch feedback.severity {
    case .success: prefix = "Success."
    case .failure: prefix = "Action failed."
    }
    let payload = AttributedString("\(prefix) \(feedback.message)")
    AccessibilityNotification.Announcement(payload).post()
  }
}
