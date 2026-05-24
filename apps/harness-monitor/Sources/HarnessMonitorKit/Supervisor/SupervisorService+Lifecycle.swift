import Foundation

extension SupervisorService {
  public func start() async {
    guard !running else { return }
    running = true
    HarnessMonitorLogger.supervisorTrace(
      "supervisor.start interval=\(self.interval)"
    )
    let loopClock = clock
    let loopInterval = interval
    let serviceReference = SupervisorServiceReference(self)
    tickTask = Task { [serviceReference, loopClock, loopInterval] in
      await Self.runLoop(
        serviceReference: serviceReference,
        clock: loopClock,
        interval: loopInterval
      )
    }
  }

  public func stop() async {
    guard running else { return }
    running = false
    tickTask?.cancel()
    // The loop task never calls stop; callers stop the service from outside the
    // loop and this drains at most the currently serialized tick.
    await awaitCurrentTick()
    _ = await tickTask?.value
    tickTask = nil
    HarnessMonitorLogger.supervisorTrace("supervisor.stop")
  }

  private static func runLoop(
    serviceReference: SupervisorServiceReference,
    clock: any SupervisorClock,
    interval: TimeInterval
  ) async {
    while !Task.isCancelled {
      guard await runLoopStep(serviceReference.service) else { return }
      do {
        try await clock.sleep(for: sleepDuration(for: interval))
      } catch {
        return
      }
    }
  }

  private static func runLoopStep(_ service: SupervisorService?) async -> Bool {
    guard let service else { return false }
    return await service.runLoopStep()
  }

  private func runLoopStep() async -> Bool {
    guard running && !Task.isCancelled else { return false }
    await runTickSerialized()
    return running && !Task.isCancelled
  }

  private static func sleepDuration(for interval: TimeInterval) -> Duration {
    guard interval.isFinite, interval > 0 else {
      return .milliseconds(1)
    }
    let milliseconds = min(Double(Int64.max), (interval * 1_000).rounded(.up))
    return .milliseconds(Int64(max(1.0, milliseconds)))
  }
}
