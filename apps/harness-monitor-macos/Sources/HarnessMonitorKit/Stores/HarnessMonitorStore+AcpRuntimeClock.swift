import Foundation

extension HarnessMonitorStore {
  /// `sampledAt` is daemon-authored time while `receivedAt` is when this client saw that sample.
  /// Advancing the daemon sample by locally elapsed wall time keeps ACP countdowns honest under
  /// daemon/client clock skew without pretending both timestamps mean the same thing.
  public func currentAcpRuntimeClockNow(at localNow: Date) -> Date? {
    guard let selectedAcpInspectState else {
      return nil
    }
    return selectedAcpInspectState.sampledAt.addingTimeInterval(
      localNow.timeIntervalSince(selectedAcpInspectState.receivedAt)
    )
  }

  /// Keep a non-observed 1 Hz clock alive only while the selected runtime has a deadline.
  ///
  /// Visible countdown views own their local invalidation so this store task does not refresh the
  /// wider session window once per second.
  func reconcileAcpRuntimeClock() {
    let localNow = Date.now
    let now = currentAcpRuntimeClockNow(at: localNow) ?? localNow
    guard hasActiveAcpRuntimeDeadline(at: now) else {
      acpRuntimeClockTask?.cancel()
      acpRuntimeClockTask = nil
      return
    }

    acpRuntimeClockTick = now
    guard acpRuntimeClockTask == nil else {
      return
    }

    acpRuntimeClockTask = Task<Void, Never> { @MainActor [weak self] in
      while let self {
        let localNow = Date.now
        let now = self.currentAcpRuntimeClockNow(at: localNow) ?? localNow
        guard self.hasActiveAcpRuntimeDeadline(at: now) else {
          self.acpRuntimeClockTask = nil
          return
        }

        do {
          try await Task.sleep(for: .seconds(1))
        } catch {
          self.acpRuntimeClockTask = nil
          return
        }

        let tickLocalNow = Date.now
        self.acpRuntimeClockTick = self.currentAcpRuntimeClockNow(at: tickLocalNow) ?? tickLocalNow
      }
    }
  }

  private func hasActiveAcpRuntimeDeadline(at now: Date) -> Bool {
    guard let observedAt = selectedAcpInspectObservedAt else {
      return false
    }

    return selectedAcpInspectAgents.contains { snapshot in
      snapshot.promptDeadlineRemainingMs > 0
        && observedAt.addingTimeInterval(TimeInterval(snapshot.promptDeadlineRemainingMs) / 1000)
          > now
    }
  }
}
