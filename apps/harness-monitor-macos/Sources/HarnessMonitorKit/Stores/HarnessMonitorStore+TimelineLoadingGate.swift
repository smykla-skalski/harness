import Foundation

@MainActor
protocol TimelineLoadingGateClock: ContinuousClockSource {
  func sleep(until deadline: ContinuousClock.Instant) async throws
}

extension LiveContinuousClockSource: TimelineLoadingGateClock {
  @MainActor
  func sleep(until deadline: ContinuousClock.Instant) async throws {
    let remaining = now.duration(to: deadline)
    if remaining > .zero {
      try await Task.sleep(for: remaining)
    }
  }
}

extension HarnessMonitorStore {
  func beginTimelineLoadingGate(hasVisibleTimeline: Bool) {
    cancelTimelineLoadingGate()
    guard !hasVisibleTimeline else {
      isTimelineLoading = false
      return
    }

    timelineLoadingGateStartedAt = timelineLoadingGateClock.now
    isTimelineLoading = true
  }

  func finishTimelineLoadingGateIfCurrent(requestID: UInt64, sessionID: String) {
    guard isCurrentSessionLoad(requestID, sessionID: sessionID) else { return }
    guard let gateStart = timelineLoadingGateStartedAt else {
      isTimelineLoading = false
      return
    }

    let deadline = gateStart.advanced(by: timelineMinimumLoadingDuration)
    timelineLoadingGateTask?.cancel()
    timelineLoadingGateTask = Task { @MainActor [weak self] in
      guard let self else { return }

      do {
        try await self.timelineLoadingGateClock.sleep(until: deadline)
      } catch is CancellationError {
        return
      } catch {
        return
      }

      guard self.isCurrentSessionLoad(requestID, sessionID: sessionID) else { return }
      self.timelineLoadingGateTask = nil
      self.timelineLoadingGateStartedAt = nil
      self.isTimelineLoading = false
    }
  }

  func cancelTimelineLoadingGate() {
    timelineLoadingGateTask?.cancel()
    timelineLoadingGateTask = nil
    timelineLoadingGateStartedAt = nil
  }
}
