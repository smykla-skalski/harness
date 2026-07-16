import Foundation
import Testing

@testable import HarnessMonitorKit

extension HarnessMonitorStoreRemoteConnectionTests {
  func makePendingReconnectStore() async throws -> PendingRemoteReconnectFixture {
    let fixture = try RemoteStoreFixture()
    let daemon = RecordingDaemonController()
    let sleeper = RecordingRemoteDaemonReconnectSleeper(behavior: .suspended)
    let store = HarnessMonitorStore(
      daemonController: daemon,
      remoteDaemonServices: fixture.services
    )
    store.connection.remoteDaemonReconnectSleeper = sleeper
    store.connectionState = .offline("remote unavailable")
    store.scheduleRemoteDaemonReconnect(after: URLError(.cannotConnectToHost))
    try await waitForRemoteReconnect {
      await sleeper.recordedDelays() == [.milliseconds(500)]
    }
    return PendingRemoteReconnectFixture(store: store, daemon: daemon, sleeper: sleeper)
  }

  func waitForRemoteReconnect(
    _ condition: @escaping @MainActor () async -> Bool
  ) async throws {
    for _ in 0..<100 {
      if await condition() {
        return
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for remote daemon reconnect state")
  }
}

struct PendingRemoteReconnectFixture {
  let store: HarnessMonitorStore
  let daemon: RecordingDaemonController
  let sleeper: RecordingRemoteDaemonReconnectSleeper
}

actor RecordingRemoteDaemonReconnectSleeper: RemoteDaemonReconnectSleeping {
  enum Behavior: Sendable {
    case immediate
    case suspended
  }

  private let behavior: Behavior
  private var delays: [Duration] = []
  private var cancellationCount = 0

  init(behavior: Behavior) {
    self.behavior = behavior
  }

  func sleep(for delay: Duration) async throws {
    delays.append(delay)
    switch behavior {
    case .immediate:
      await Task.yield()
      try Task.checkCancellation()
    case .suspended:
      do {
        try await Task.sleep(for: .seconds(3_600))
      } catch {
        cancellationCount += 1
        throw error
      }
    }
  }

  func recordedDelays() -> [Duration] {
    delays
  }

  func recordedCancellationCount() -> Int {
    cancellationCount
  }
}
