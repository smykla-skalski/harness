import Foundation

extension HarnessMonitorStore {
  /// Keep one store-owned 1 Hz tick for the selected runtime strip only.
  ///
  /// The countdown must survive view recreation without each strip spinning up its own timer, but
  /// it should stay dormant unless the selected inspect sample currently contains a live deadline.
  func reconcileAcpRuntimeClock() {
    let now = Date.now
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
        guard self.hasActiveAcpRuntimeDeadline(at: .now) else {
          self.acpRuntimeClockTask = nil
          return
        }

        do {
          try await Task.sleep(for: .seconds(1))
        } catch {
          self.acpRuntimeClockTask = nil
          return
        }

        self.acpRuntimeClockTick = .now
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
