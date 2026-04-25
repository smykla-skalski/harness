import Foundation
import Testing

@testable import HarnessMonitorKit

private final class DurationLog: @unchecked Sendable {
  private let lock = NSLock()
  private var entries: [Duration] = []

  func append(_ duration: Duration) {
    lock.withLock {
      entries.append(duration)
    }
  }

  func snapshot() -> [Duration] {
    lock.withLock { entries }
  }
}

@Suite("Warm-up backoff iterator")
struct WarmUpBackoffIteratorTests {
  @Test("iterator grows the wait interval on consecutive no-progress waits")
  func iteratorGrowsIntervalOnConsecutiveWaits() async throws {
    let log = DurationLog()
    let backoff = WarmUpBackoff(
      initial: .milliseconds(100),
      multiplier: 2.0,
      cap: .seconds(1),
      sleeper: { duration in
        log.append(duration)
      }
    )
    var iterator = backoff.makeIterator()
    try await iterator.wait()
    try await iterator.wait()
    try await iterator.wait()
    try await iterator.wait()

    let observed = log.snapshot()
    #expect(
      observed == [
        .milliseconds(100), .milliseconds(200), .milliseconds(400), .milliseconds(800),
      ]
    )
  }

  @Test("iterator caps the wait interval and stays at the cap")
  func iteratorCapsWaitInterval() async throws {
    let log = DurationLog()
    let backoff = WarmUpBackoff(
      initial: .milliseconds(250),
      multiplier: 1.5,
      cap: .milliseconds(1500),
      sleeper: { log.append($0) }
    )
    var iterator = backoff.makeIterator()
    for _ in 0..<8 {
      try await iterator.wait()
    }

    let observed = log.snapshot()
    #expect(observed.last == .milliseconds(1500))
    #expect(observed.allSatisfy { $0 <= .milliseconds(1500) })
    #expect(observed.contains(.milliseconds(1500)))
  }

  @Test("iterator resets to the initial interval when reset() is called")
  func iteratorResetsToInitialInterval() async throws {
    let log = DurationLog()
    let backoff = WarmUpBackoff(
      initial: .milliseconds(100),
      multiplier: 2.0,
      cap: .seconds(1),
      sleeper: { log.append($0) }
    )
    var iterator = backoff.makeIterator()
    try await iterator.wait()
    try await iterator.wait()
    try await iterator.wait()
    iterator.reset()
    try await iterator.wait()
    try await iterator.wait()

    let observed = log.snapshot()
    #expect(
      observed == [
        .milliseconds(100),
        .milliseconds(200),
        .milliseconds(400),
        .milliseconds(100),
        .milliseconds(200),
      ]
    )
  }

  @Test("default backoff matches the warm-up loop curve")
  func defaultBackoffCurveIsCorrect() {
    let backoff = WarmUpBackoff.default
    #expect(backoff.initial == .milliseconds(250))
    #expect(backoff.multiplier == 1.5)
    #expect(backoff.cap == .milliseconds(1500))
  }
}

@Suite("Warm-up loop drives the backoff iterator")
struct DaemonControllerWarmUpBackoffWiringTests {
  @Test("awaitManifestWarmUp grows wait between repeated stale observations")
  func awaitManifestWarmUpGrowsWaitBetweenStaleObservations() async throws {
    try await withTempDaemonFixture(pid: UInt32(getpid())) { environment in
      let log = DurationLog()
      let controller = DaemonController(
        environment: environment,
        launchAgentManager: RecordingLaunchAgentManager(state: .enabled),
        ownership: .managed,
        endpointProbe: { _ in false },
        managedStaleManifestGracePeriod: .seconds(60),
        warmUpBackoff: WarmUpBackoff(
          initial: .milliseconds(10),
          multiplier: 2.0,
          cap: .milliseconds(80),
          sleeper: { log.append($0) }
        )
      )

      _ = try? await controller.awaitManifestWarmUp(timeout: .milliseconds(50))

      let observed = log.snapshot()
      // Iteration 1 fires .progressedLoop (first observation of stale signature)
      // → backoff.reset() then wait() at initial. Subsequent iterations stay
      // .withinGrace and ramp: 10ms → 20ms → 40ms → 80ms (cap).
      #expect(observed.count >= 4)
      let prefix = Array(observed.prefix(4))
      #expect(
        prefix == [.milliseconds(10), .milliseconds(20), .milliseconds(40), .milliseconds(80)]
      )
      #expect(observed.allSatisfy { $0 <= .milliseconds(80) })
    }
  }
}
