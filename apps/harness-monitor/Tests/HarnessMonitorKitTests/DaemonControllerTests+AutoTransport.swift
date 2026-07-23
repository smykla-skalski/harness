import Foundation
import Testing

@testable import HarnessMonitorKit

final class LockedFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  func set() {
    lock.withLock { value = true }
  }

  func get() -> Bool {
    lock.withLock { value }
  }
}

@Suite("Daemon controller auto transport")
struct DaemonControllerAutoTransportTests {
  @Test(
    "auto transport bootstrap upgrades to WebSocket when it becomes ready within the default grace period"
  )
  func autoTransportBootstrapUpgradesToWebSocketWithinDefaultGracePeriod() async throws {
    let httpClient = RecordingHarnessClient()
    let webSocketClient = RecordingHarnessClient()
    let controller = DaemonController(
      transportPreference: .auto,
      launchAgentManager: RecordingLaunchAgentManager(state: .enabled),
      sessionFactory: { _ in httpClient },
      webSocketBootstrapper: { _ in
        try? await Task.sleep(for: .milliseconds(400))
        return webSocketClient
      }
    )
    let connection = HarnessMonitorConnection(
      endpoint: try #require(URL(string: "http://127.0.0.1:65535")),
      token: "test-token"
    )
    let clock = ContinuousClock()
    let start = clock.now

    let client = try await controller.bootstrap(connection: connection)

    let elapsed = start.duration(to: clock.now)
    #expect(client as AnyObject === webSocketClient as AnyObject)
    #expect(elapsed >= .milliseconds(300))
    #expect(elapsed < .seconds(2))
    #expect(httpClient.readCallCount(.health) == 1)
    #expect(httpClient.shutdownCallCount() == 1)
    #expect(webSocketClient.shutdownCallCount() == 0)
  }

  @Test("auto transport bootstrap falls back after the configured WebSocket grace period")
  func autoTransportBootstrapFallsBackAfterConfiguredGracePeriod() async throws {
    let httpClient = RecordingHarnessClient()
    let webSocketClient = RecordingHarnessClient()
    // Model a daemon that accepts the socket and never answers: the connect
    // stays in flight past the grace period and ignores cooperative cancel.
    let hangDuration: Duration = .milliseconds(600)
    let gracePeriod: Duration = .milliseconds(150)
    let controller = DaemonController(
      transportPreference: .auto,
      launchAgentManager: RecordingLaunchAgentManager(state: .enabled),
      ownership: .managed,
      autoTransportWebSocketGracePeriod: gracePeriod,
      sessionFactory: { _ in httpClient },
      webSocketBootstrapper: { _ in
        await withCheckedContinuation {
          (continuation: CheckedContinuation<(any HarnessMonitorClientProtocol)?, Never>) in
          Task.detached {
            try? await Task.sleep(for: hangDuration)
            continuation.resume(returning: webSocketClient)
          }
        }
      }
    )
    let connection = HarnessMonitorConnection(
      endpoint: try #require(URL(string: "http://127.0.0.1:65535")),
      token: "test-token"
    )
    let clock = ContinuousClock()
    let start = clock.now

    let client = try await controller.bootstrap(connection: connection)

    let elapsed = start.duration(to: clock.now)
    #expect(client as AnyObject === httpClient as AnyObject)
    // Wait must honor the grace period even while the WebSocket attempt is still
    // in flight; do not block startup on the hang finishing.
    #expect(elapsed < .milliseconds(300))
    #expect(elapsed < hangDuration)
    #expect(httpClient.readCallCount(.health) == 1)
    #expect(httpClient.shutdownCallCount() == 0)

    // Late winner still has to be shut down once it lands (#360).
    let shutdownDeadline = clock.now + hangDuration + .milliseconds(500)
    while webSocketClient.shutdownCallCount() == 0, clock.now < shutdownDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(webSocketClient.shutdownCallCount() == 1)
  }

  @Test("auto transport grace timeout cancels the in-flight WebSocket attempt")
  func autoTransportGraceTimeoutCancelsInFlightWebSocketAttempt() async throws {
    let httpClient = RecordingHarnessClient()
    let cancelObserved = LockedFlag()
    let gracePeriod: Duration = .milliseconds(100)
    let controller = DaemonController(
      transportPreference: .auto,
      launchAgentManager: RecordingLaunchAgentManager(state: .enabled),
      ownership: .managed,
      autoTransportWebSocketGracePeriod: gracePeriod,
      sessionFactory: { _ in httpClient },
      webSocketBootstrapper: { _ in
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(20))
        }
        cancelObserved.set()
        // A cancelled attempt must not hand back a live client.
        return nil
      }
    )
    let connection = HarnessMonitorConnection(
      endpoint: try #require(URL(string: "http://127.0.0.1:65535")),
      token: "test-token"
    )
    let clock = ContinuousClock()
    let start = clock.now

    let client = try await controller.bootstrap(connection: connection)

    let elapsed = start.duration(to: clock.now)
    #expect(client as AnyObject === httpClient as AnyObject)
    #expect(elapsed < .milliseconds(300))
    #expect(httpClient.readCallCount(.health) == 1)
    #expect(httpClient.shutdownCallCount() == 0)

    let cancelDeadline = clock.now + .milliseconds(500)
    while !cancelObserved.get(), clock.now < cancelDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(cancelObserved.get())
  }

  @Test("cancelled WebSocket bootstrap reports cancellation, not a connection failure")
  func cancelledWebSocketBootstrapReportsCancellation() async throws {
    let attemptStarted = LockedFlag()
    let controller = DaemonController(
      transportPreference: .webSocket,
      launchAgentManager: RecordingLaunchAgentManager(state: .enabled),
      ownership: .managed,
      webSocketBootstrapper: { _ in
        attemptStarted.set()
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
      }
    )
    let connection = HarnessMonitorConnection(
      endpoint: try #require(URL(string: "http://127.0.0.1:65535")),
      token: "test-token"
    )

    let bootstrap = Task { try await controller.bootstrap(connection: connection) }
    let clock = ContinuousClock()
    let startDeadline = clock.now + .seconds(2)
    while !attemptStarted.get(), clock.now < startDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(attemptStarted.get())
    bootstrap.cancel()

    // A nil attempt means "no WebSocket" and "we called it off" alike. Reporting
    // the caller's own cancellation as a connection failure makes the store
    // toast an offline banner and schedule a reconnect for nothing.
    await #expect(throws: CancellationError.self) {
      _ = try await bootstrap.value
    }
  }

  @Test("default WebSocket bootstrap stops a hung health probe on cancel")
  func defaultWebSocketBootstrapStopsHungHealthProbeOnCancel() async throws {
    // Binds and listens but never accepts, so the upgrade request is sent and
    // never answered - the daemon this grace period exists for.
    let listener = try LoopbackListener()
    defer { listener.close() }
    let connection = HarnessMonitorConnection(
      endpoint: try #require(URL(string: "http://127.0.0.1:\(listener.port)")),
      token: "test-token"
    )

    let attempt = Task { await DaemonController.defaultWebSocketBootstrap(connection) }
    try await Task.sleep(for: .milliseconds(200))
    let clock = ContinuousClock()
    let start = clock.now
    attempt.cancel()
    let client = await attempt.value
    let elapsed = start.duration(to: clock.now)

    #expect(client == nil)
    // Cancellation alone cannot unwind the pending health RPC. Without the
    // transport shutdown that fails it, this would sit on URLSession's 15s
    // request timeout or the 120s RPC timeout instead.
    #expect(elapsed < .seconds(2))
  }
}
