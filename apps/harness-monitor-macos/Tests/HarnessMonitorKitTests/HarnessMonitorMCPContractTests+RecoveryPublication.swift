import Foundation
import Testing

@testable import HarnessMonitorKit

extension HarnessMonitorMCPContractTests {
  @Test("disable publishes single disabled snapshot when clearing recovery state")
  func disablePublishesSingleDisabledSnapshotWhenClearingRecoveryState() async throws {
    let defaults = try isolatedRecoveryDefaults()
    defaults.defaults.set(true, forKey: HarnessMonitorMCPPreferencesDefaults.registryHostEnabledKey)
    defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }

    let notificationCenter = NotificationCenter()
    let clock = TestClock()
    let degradedState = HarnessMonitorMCPRuntimeState.degraded(
      socketPath: "/tmp/mcp.sock",
      reason: "listener bind failed"
    )
    let service = RecoveryStubMCPService(nextEnabledRuntimeStates: [degradedState])
    let controller = HarnessMonitorMCPStartupController(
      service: service,
      defaults: defaults.defaults,
      notificationCenter: notificationCenter,
      recoveryPolicy: HarnessMonitorMCPRecoveryPolicy(
        maximumRetryCount: 2,
        retryDelay: .seconds(5),
        healthCheckInterval: nil
      ),
      forceEnable: { false },
      sleep: clock.sleep(for:)
    )

    var publishedSnapshots: [HarnessMonitorMCPStatusSnapshot] = []
    controller.statusDidChange = { publishedSnapshots.append($0) }

    controller.start()
    await waitForCondition {
      controller.runtimeState == degradedState
        && controller.recoveryStatus
          == HarnessMonitorMCPRecoveryStatus(
            completedRetryCount: 0,
            maximumRetryCount: 2,
            nextRetryDelay: .seconds(5)
          )
    }

    #expect(
      publishedSnapshots.last
        == HarnessMonitorMCPStatusSnapshot(
          runtimeState: degradedState,
          recoveryStatus: HarnessMonitorMCPRecoveryStatus(
            completedRetryCount: 0,
            maximumRetryCount: 2,
            nextRetryDelay: .seconds(5)
          )
        )
    )
    #expect(
      publishedSnapshots.contains(
        HarnessMonitorMCPStatusSnapshot(
          runtimeState: degradedState,
          recoveryStatus: nil
        )
      ) == false
    )

    publishedSnapshots.removeAll()

    defaults.defaults.set(
      false,
      forKey: HarnessMonitorMCPPreferencesDefaults.registryHostEnabledKey
    )
    notificationCenter.post(name: UserDefaults.didChangeNotification, object: defaults.defaults)
    await waitForCondition {
      controller.runtimeState == HarnessMonitorMCPRuntimeState.disabled
    }

    #expect(
      publishedSnapshots
        == [
          HarnessMonitorMCPStatusSnapshot(
            runtimeState: .disabled,
            recoveryStatus: nil
          )
        ]
    )

    await controller.stop()
  }

  @Test("health check failure publishes recovery-aware degraded snapshot")
  func healthCheckFailurePublishesRecoveryAwareDegradedSnapshot() async throws {
    let defaults = try isolatedRecoveryDefaults()
    defaults.defaults.set(true, forKey: HarnessMonitorMCPPreferencesDefaults.registryHostEnabledKey)
    defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }

    let clock = TestClock()
    let degradedState = HarnessMonitorMCPRuntimeState.degraded(
      socketPath: "/tmp/mcp.sock",
      reason: "connection lost"
    )
    let service = RecoveryStubMCPService(
      nextEnabledRuntimeStates: [
        .healthy(socketPath: "/tmp/mcp.sock"),
        .healthy(socketPath: "/tmp/mcp.sock"),
      ]
    )
    service.nextProbeRuntimeStates = [degradedState]
    let controller = HarnessMonitorMCPStartupController(
      service: service,
      defaults: defaults.defaults,
      notificationCenter: NotificationCenter(),
      recoveryPolicy: HarnessMonitorMCPRecoveryPolicy(
        maximumRetryCount: 1,
        retryDelay: .seconds(5),
        healthCheckInterval: .seconds(10)
      ),
      forceEnable: { false },
      sleep: clock.sleep(for:)
    )

    var publishedSnapshots: [HarnessMonitorMCPStatusSnapshot] = []
    controller.statusDidChange = { publishedSnapshots.append($0) }

    controller.start()
    await waitForCondition {
      controller.runtimeState
        == HarnessMonitorMCPRuntimeState.healthy(socketPath: "/tmp/mcp.sock")
        && clock.pendingSleepCount == 1
    }

    publishedSnapshots.removeAll()

    await clock.advance(by: .seconds(10))
    await waitForCondition {
      controller.runtimeState == degradedState
        && controller.recoveryStatus
          == HarnessMonitorMCPRecoveryStatus(
            completedRetryCount: 0,
            maximumRetryCount: 1,
            nextRetryDelay: .seconds(5)
          )
    }

    #expect(
      publishedSnapshots.last
        == HarnessMonitorMCPStatusSnapshot(
          runtimeState: degradedState,
          recoveryStatus: HarnessMonitorMCPRecoveryStatus(
            completedRetryCount: 0,
            maximumRetryCount: 1,
            nextRetryDelay: .seconds(5)
          )
        )
    )
    #expect(
      publishedSnapshots.contains(
        HarnessMonitorMCPStatusSnapshot(
          runtimeState: degradedState,
          recoveryStatus: nil
        )
      ) == false
    )

    await controller.stop()
  }
}
