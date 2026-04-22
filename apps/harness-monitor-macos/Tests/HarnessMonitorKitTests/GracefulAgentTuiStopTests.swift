import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("performGracefulStop")
struct GracefulAgentTuiStopTests {
  static let fastTiming = GracefulAgentTuiStopTiming(
    escapeGap: .milliseconds(1),
    postEscapePause: .milliseconds(1),
    gracePeriod: .milliseconds(5),
    pollInterval: .milliseconds(1)
  )

  static let expectedCooperativeSequence: [AgentTuiInput] = [
    .key(.escape),
    .key(.escape),
    .text("/exit"),
    .key(.enter),
  ]

  @Test("sends two escapes, /exit, and enter in order")
  func sendsCooperativeSequence() async {
    let stopper = RecordingStopper(activeSequence: [false])

    await performGracefulStop(
      tuiID: "tui-1",
      stopper: stopper,
      timing: Self.fastTiming,
      sleep: noSleep
    )

    let inputs = await stopper.capturedInputs
    #expect(inputs == Self.expectedCooperativeSequence)
    let targets = await stopper.capturedTargets
    #expect(targets.allSatisfy { $0 == "tui-1" })
  }

  @Test("skips hard stop when agent exits during grace window")
  func skipsHardStopOnCooperativeExit() async {
    let stopper = RecordingStopper(activeSequence: [false])

    await performGracefulStop(
      tuiID: "tui-1",
      stopper: stopper,
      timing: Self.fastTiming,
      sleep: noSleep
    )

    let stops = await stopper.capturedStops
    #expect(stops.isEmpty)
  }

  @Test("falls back to hard stop after grace window elapses")
  func hardStopFallback() async {
    let stopper = RecordingStopper(activeSequence: [true])

    await performGracefulStop(
      tuiID: "tui-1",
      stopper: stopper,
      timing: Self.fastTiming,
      sleep: noSleep
    )

    let stops = await stopper.capturedStops
    #expect(stops == ["tui-1"])
  }

  @Test("falls back to hard stop when any input send fails")
  func hardStopOnInputFailure() async {
    let stopper = RecordingStopper(
      activeSequence: [false],
      inputResult: false
    )

    await performGracefulStop(
      tuiID: "tui-1",
      stopper: stopper,
      timing: Self.fastTiming,
      sleep: noSleep
    )

    let inputs = await stopper.capturedInputs
    #expect(inputs.count == Self.expectedCooperativeSequence.count)
    let stops = await stopper.capturedStops
    #expect(stops == ["tui-1"])
  }

  @Test("respects configured timing for escape gap and post-escape pause")
  func respectsCustomTiming() async {
    let stopper = RecordingStopper(activeSequence: [false])
    let recorder = SleepRecorder()
    let timing = GracefulAgentTuiStopTiming(
      escapeGap: .milliseconds(150),
      postEscapePause: .milliseconds(80),
      gracePeriod: .seconds(10),
      pollInterval: .milliseconds(250)
    )

    await performGracefulStop(
      tuiID: "tui-1",
      stopper: stopper,
      timing: timing,
      sleep: { duration in await recorder.record(duration) }
    )

    let values = await recorder.values
    #expect(values.count >= 2)
    #expect(values[0] == .milliseconds(150))
    #expect(values[1] == .milliseconds(80))
  }
}

private let noSleep: @Sendable (Duration) async -> Void = { _ in }

private actor RecordingStopper: GracefulAgentTuiStopper {
  private let inputResult: Bool
  private let stopResult: Bool
  private let activeSequence: [Bool]
  private var activeCallCount = 0
  private(set) var capturedInputs: [AgentTuiInput] = []
  private(set) var capturedTargets: [String] = []
  private(set) var capturedStops: [String] = []

  init(
    activeSequence: [Bool],
    inputResult: Bool = true,
    stopResult: Bool = true
  ) {
    self.activeSequence = activeSequence
    self.inputResult = inputResult
    self.stopResult = stopResult
  }

  func sendInput(tuiID: String, input: AgentTuiInput) async -> Bool {
    capturedInputs.append(input)
    capturedTargets.append(tuiID)
    return inputResult
  }

  func stop(tuiID: String) async -> Bool {
    capturedStops.append(tuiID)
    return stopResult
  }

  func isActive(tuiID: String) async -> Bool {
    let index = min(activeCallCount, activeSequence.count - 1)
    activeCallCount += 1
    return activeSequence[index]
  }
}

private actor SleepRecorder {
  private(set) var values: [Duration] = []

  func record(_ duration: Duration) {
    values.append(duration)
  }
}
