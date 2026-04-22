import Foundation

public protocol GracefulAgentTuiStopper: Sendable {
  func sendInput(tuiID: String, input: AgentTuiInput) async -> Bool
  func stop(tuiID: String) async -> Bool
  func isActive(tuiID: String) async -> Bool
}

public struct GracefulAgentTuiStopTiming: Sendable {
  public var escapeGap: Duration
  public var postEscapePause: Duration
  public var gracePeriod: Duration
  public var pollInterval: Duration

  public init(
    escapeGap: Duration = .milliseconds(150),
    postEscapePause: Duration = .milliseconds(80),
    gracePeriod: Duration = .seconds(10),
    pollInterval: Duration = .milliseconds(250)
  ) {
    self.escapeGap = escapeGap
    self.postEscapePause = postEscapePause
    self.gracePeriod = gracePeriod
    self.pollInterval = pollInterval
  }
}

public func performGracefulStop(
  tuiID: String,
  stopper: any GracefulAgentTuiStopper,
  timing: GracefulAgentTuiStopTiming = GracefulAgentTuiStopTiming(),
  sleep: @Sendable (Duration) async -> Void = { duration in
    try? await Task.sleep(for: duration)
  }
) async {
  var anyInputFailed = false

  func deliver(_ input: AgentTuiInput) async {
    let success = await stopper.sendInput(tuiID: tuiID, input: input)
    if !success {
      anyInputFailed = true
      HarnessMonitorLogger.store.warning(
        "graceful stop input failed for \(tuiID, privacy: .public)"
      )
    }
  }

  await deliver(.key(.escape))
  await sleep(timing.escapeGap)
  await deliver(.key(.escape))
  await sleep(timing.postEscapePause)
  await deliver(.text("/exit"))
  await deliver(.key(.enter))

  let cooperative = await waitForInactivity(
    tuiID: tuiID,
    stopper: stopper,
    timing: timing,
    sleep: sleep
  )

  if !cooperative || anyInputFailed {
    _ = await stopper.stop(tuiID: tuiID)
  }
}

private func waitForInactivity(
  tuiID: String,
  stopper: any GracefulAgentTuiStopper,
  timing: GracefulAgentTuiStopTiming,
  sleep: @Sendable (Duration) async -> Void
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timing.gracePeriod)
  while clock.now < deadline {
    if await !stopper.isActive(tuiID: tuiID) {
      return true
    }
    await sleep(timing.pollInterval)
  }
  return await !stopper.isActive(tuiID: tuiID)
}

@MainActor
public struct StoreBackedAgentTuiStopper: GracefulAgentTuiStopper {
  private let store: HarnessMonitorStore

  public init(store: HarnessMonitorStore) {
    self.store = store
  }

  public func sendInput(tuiID: String, input: AgentTuiInput) async -> Bool {
    await store.sendAgentTuiInput(
      tuiID: tuiID,
      input: input,
      showSuccessFeedback: false
    )
  }

  public func stop(tuiID: String) async -> Bool {
    await store.stopAgentTui(tuiID: tuiID)
  }

  public func isActive(tuiID: String) -> Bool {
    store.selectedAgentTuis.first(where: { $0.tuiId == tuiID })?.status.isActive ?? false
  }
}
