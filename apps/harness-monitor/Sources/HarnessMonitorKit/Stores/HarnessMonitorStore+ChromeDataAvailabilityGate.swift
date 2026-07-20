import Foundation

extension HarnessMonitorStore {
  /// A non-live availability still waiting out the grace period before it may
  /// open the window chrome.
  struct PendingChromeDataAvailability {
    var availability: SessionDataAvailability
    var deadline: ContinuousClock.Instant
  }

  /// Data availability as the window chrome should present it.
  ///
  /// `sessionDataAvailability` tracks the connection state machine exactly,
  /// and that machine legitimately bounces between `.offline` and
  /// `.connecting` while recovery retries. Rendering it directly made the
  /// banner blink and shove the window content down and back up on every
  /// short reconnect. Two rules remove that: a non-live state must survive
  /// `chromeDataAvailabilityGracePeriod` before it is shown, and once shown it
  /// stays until the connection is genuinely live again.
  func resolveChromeDataAvailability() -> SessionDataAvailability {
    // Preview and UI-test stores are seeded into a fixed state and never
    // reconnect, so there is no churn to absorb and nothing to wait for.
    guard maintainsLiveDaemonObservation else {
      return sessionDataAvailability
    }
    guard let candidate = chromeDataAvailabilityCandidate() else {
      clearChromeDataAvailabilityGate()
      return .live
    }

    if connection.presentedChromeDataAvailability != nil {
      // Already visible: track the newest reason rather than re-running the
      // grace period, so the banner never drops out mid-recovery.
      connection.presentedChromeDataAvailability = candidate
      return candidate
    }

    let now = ContinuousClock.now
    let deadline =
      connection.pendingChromeDataAvailability?.deadline
      ?? now.advanced(by: chromeDataAvailabilityGracePeriod)
    guard deadline > now else {
      presentChromeDataAvailability(candidate)
      return candidate
    }

    connection.pendingChromeDataAvailability = PendingChromeDataAvailability(
      availability: candidate,
      deadline: deadline
    )
    armChromeDataAvailabilityGate(until: deadline)
    return .live
  }

  func cancelChromeDataAvailabilityGateTask() {
    connection.chromeDataAvailabilityGateTask?.cancel()
    connection.chromeDataAvailabilityGateTask = nil
  }

  /// The non-live availability the chrome would show, or `nil` when the
  /// connection is live and nothing is waiting.
  private func chromeDataAvailabilityCandidate() -> SessionDataAvailability? {
    let availability = sessionDataAvailability
    guard availability == .live else {
      return availability
    }
    guard connectionState != .online else {
      return nil
    }
    // A reconnect leg reports `.live` because no offline reason is recorded
    // while connecting; reuse the reason already in flight so a retry cannot
    // blank the banner mid-recovery.
    return connection.presentedChromeDataAvailability
      ?? connection.pendingChromeDataAvailability?.availability
  }

  private func presentChromeDataAvailability(_ availability: SessionDataAvailability) {
    connection.presentedChromeDataAvailability = availability
    connection.pendingChromeDataAvailability = nil
    cancelChromeDataAvailabilityGateTask()
  }

  private func clearChromeDataAvailabilityGate() {
    connection.presentedChromeDataAvailability = nil
    connection.pendingChromeDataAvailability = nil
    cancelChromeDataAvailabilityGateTask()
  }

  /// Re-syncs the chrome once the grace period expires. Without it a daemon
  /// that stays down emits no further state change, so the banner would never
  /// appear.
  private func armChromeDataAvailabilityGate(until deadline: ContinuousClock.Instant) {
    guard connection.chromeDataAvailabilityGateTask == nil else {
      return
    }
    connection.chromeDataAvailabilityGateTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(until: deadline, clock: .continuous)
      } catch {
        return
      }
      guard let self else {
        return
      }
      connection.chromeDataAvailabilityGateTask = nil
      scheduleUISync([.contentChrome])
    }
  }
}
