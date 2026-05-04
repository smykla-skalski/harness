import Foundation

extension HarnessMonitorStore {
  /// `sampledAt` is daemon-authored time while `receivedAt` is when this client saw that sample.
  /// Advancing the daemon sample by locally elapsed wall time keeps ACP countdowns honest under
  /// daemon/client clock skew without pretending both timestamps mean the same thing.
  func currentAcpRuntimeClockNow(at localNow: Date) -> Date? {
    guard let selectedAcpInspectState else {
      return nil
    }
    return selectedAcpInspectState.sampledAt.addingTimeInterval(
      localNow.timeIntervalSince(selectedAcpInspectState.receivedAt)
    )
  }

  /// Keep one store-owned 1 Hz tick for the selected runtime strip only.
  ///
  /// The countdown must survive view recreation without each strip spinning up its own timer, but
  /// it should stay dormant unless the selected inspect sample currently contains a live deadline.
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
