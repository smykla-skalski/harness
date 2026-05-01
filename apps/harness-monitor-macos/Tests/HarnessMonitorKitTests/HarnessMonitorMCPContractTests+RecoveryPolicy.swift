import Foundation
import Testing

@testable import HarnessMonitorKit

extension HarnessMonitorMCPContractTests {
  @Test("degraded startup schedules bounded recovery and converges healthy")
  func degradedStartupSchedulesBoundedRecoveryAndConvergesHealthy() async throws {
    let defaults = try isolatedRecoveryDefaults()
    defaults.defaults.set(true, forKey: HarnessMonitorMCPPreferencesDefaults.registryHostEnabledKey)
    defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }

    let clock = TestClock()
    let degradedState = HarnessMonitorMCPRuntimeState.degraded(
      socketPath: "/tmp/mcp.sock",
      reason: "listener bind failed"
    )
    let service = RecoveryStubMCPService(
      nextEnabledRuntimeStates: [
        degradedState,
        .healthy(socketPath: "/tmp/mcp.sock"),
      ]
    )
    let controller = HarnessMonitorMCPStartupController(
      service: service,
      defaults: defaults.defaults,
      notificationCenter: NotificationCenter(),
      recoveryPolicy: HarnessMonitorMCPRecoveryPolicy(
        maximumRetryCount: 2,
        retryDelay: .seconds(5),
        healthCheckInterval: nil
      ),
      forceEnable: { false },
      sleep: clock.sleep(for:)
    )

    controller.start()
    await waitForCondition {
      controller.recoveryStatus
        == HarnessMonitorMCPRecoveryStatus(
          completedRetryCount: 0,
          maximumRetryCount: 2,
          nextRetryDelay: .seconds(5)
        )
    }

    #expect(controller.runtimeState == degradedState)
    #expect(
      controller.recoveryStatus
        == HarnessMonitorMCPRecoveryStatus(
          completedRetryCount: 0,
          maximumRetryCount: 2,
          nextRetryDelay: .seconds(5)
        )
    )

    await clock.advance(by: .seconds(5))
    await waitForCondition {
      service.recordedEnabledStates == [true, true]
        && controller.runtimeState
          == HarnessMonitorMCPRuntimeState.healthy(socketPath: "/tmp/mcp.sock")
    }

    #expect(service.recordedEnabledStates == [true, true])
    #expect(
      controller.runtimeState
        == HarnessMonitorMCPRuntimeState.healthy(socketPath: "/tmp/mcp.sock")
    )
    #expect(controller.recoveryStatus == nil)

    await controller.stop()
  }

  @Test("degraded startup exhausts its bounded retries")
  func degradedStartupExhaustsItsBoundedRetries() async throws {
    let defaults = try isolatedRecoveryDefaults()
    defaults.defaults.set(true, forKey: HarnessMonitorMCPPreferencesDefaults.registryHostEnabledKey)
    defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }

    let clock = TestClock()
    let degradedState = HarnessMonitorMCPRuntimeState.degraded(
      socketPath: "/tmp/mcp.sock",
      reason: "listener bind failed"
    )
    let service = RecoveryStubMCPService(
      nextEnabledRuntimeStates: [
        degradedState,
        degradedState,
        degradedState,
      ],
      fallbackEnabledRuntimeState: degradedState
    )
    let controller = HarnessMonitorMCPStartupController(
      service: service,
      defaults: defaults.defaults,
      notificationCenter: NotificationCenter(),
      recoveryPolicy: HarnessMonitorMCPRecoveryPolicy(
        maximumRetryCount: 2,
        retryDelay: .seconds(5),
        healthCheckInterval: nil
      ),
      forceEnable: { false },
      sleep: clock.sleep(for:)
    )

    controller.start()
    await waitForCondition {
      controller.recoveryStatus
        == HarnessMonitorMCPRecoveryStatus(
          completedRetryCount: 0,
          maximumRetryCount: 2,
          nextRetryDelay: .seconds(5)
        )
    }

    #expect(
      controller.recoveryStatus
        == HarnessMonitorMCPRecoveryStatus(
          completedRetryCount: 0,
          maximumRetryCount: 2,
          nextRetryDelay: .seconds(5)
        )
    )

    await clock.advance(by: .seconds(5))
    await waitForCondition {
      controller.recoveryStatus
        == HarnessMonitorMCPRecoveryStatus(
          completedRetryCount: 1,
          maximumRetryCount: 2,
          nextRetryDelay: .seconds(5)
        )
    }

    #expect(
      controller.recoveryStatus
        == HarnessMonitorMCPRecoveryStatus(
          completedRetryCount: 1,
          maximumRetryCount: 2,
          nextRetryDelay: .seconds(5)
        )
    )

    await clock.advance(by: .seconds(5))
    await waitForCondition {
      service.recordedEnabledStates == [true, true, true]
        && controller.recoveryStatus
          == HarnessMonitorMCPRecoveryStatus(
            completedRetryCount: 2,
            maximumRetryCount: 2,
            nextRetryDelay: nil
          )
    }

    #expect(service.recordedEnabledStates == [true, true, true])
    #expect(controller.runtimeState == degradedState)
    #expect(
      controller.recoveryStatus
        == HarnessMonitorMCPRecoveryStatus(
          completedRetryCount: 2,
          maximumRetryCount: 2,
          nextRetryDelay: nil
        )
    )
    #expect(clock.pendingSleepCount == 0)

    await controller.stop()
  }

  @Test("disable cancels pending recovery before retry runs")
  func disableCancelsPendingRecoveryBeforeRetryRuns() async throws {
    let defaults = try isolatedRecoveryDefaults()
    defaults.defaults.set(true, forKey: HarnessMonitorMCPPreferencesDefaults.registryHostEnabledKey)
    defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }

    let notificationCenter = NotificationCenter()
    let clock = TestClock()
    let service = RecoveryStubMCPService(
      nextEnabledRuntimeStates: [
        .degraded(socketPath: "/tmp/mcp.sock", reason: "listener bind failed")
      ]
    )
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

    controller.start()
    await waitForCondition {
      clock.pendingSleepCount == 1
    }
    #expect(clock.pendingSleepCount == 1)

    defaults.defaults.set(
      false,
      forKey: HarnessMonitorMCPPreferencesDefaults.registryHostEnabledKey
    )
    notificationCenter.post(name: UserDefaults.didChangeNotification, object: defaults.defaults)
    await waitForCondition {
      controller.runtimeState == HarnessMonitorMCPRuntimeState.disabled
        && clock.pendingSleepCount == 0
    }

    #expect(controller.runtimeState == HarnessMonitorMCPRuntimeState.disabled)
    #expect(controller.recoveryStatus == nil)
    #expect(clock.pendingSleepCount == 0)

    await clock.advance(by: .seconds(5))

    #expect(service.recordedEnabledStates == [true, false])

    await controller.stop()
  }

  @Test("healthy state schedules recovery when health check detects broken connection")
  func healthyStateSchedulesRecoveryWhenHealthCheckDetectsBrokenConnection() async throws {
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
        degradedState,
        .healthy(socketPath: "/tmp/mcp.sock"),
      ]
    )
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

    controller.start()
    await waitForCondition {
      controller.runtimeState
        == HarnessMonitorMCPRuntimeState.healthy(socketPath: "/tmp/mcp.sock")
        && clock.pendingSleepCount == 1
    }

    #expect(
      controller.runtimeState
        == HarnessMonitorMCPRuntimeState.healthy(socketPath: "/tmp/mcp.sock")
    )
    #expect(controller.recoveryStatus == nil)

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

    #expect(controller.runtimeState == degradedState)
    #expect(
      controller.recoveryStatus
        == HarnessMonitorMCPRecoveryStatus(
          completedRetryCount: 0,
          maximumRetryCount: 1,
          nextRetryDelay: .seconds(5)
        )
    )

    await clock.advance(by: .seconds(5))
    await waitForCondition {
      service.recordedEnabledStates == [true, true, true]
        && controller.runtimeState
          == HarnessMonitorMCPRuntimeState.healthy(socketPath: "/tmp/mcp.sock")
    }

    #expect(service.recordedEnabledStates == [true, true, true])
    #expect(
      controller.runtimeState
        == HarnessMonitorMCPRuntimeState.healthy(socketPath: "/tmp/mcp.sock")
    )
    #expect(controller.recoveryStatus == nil)

    await controller.stop()
  }

  @Test("re-enable after exhausted recovery starts fresh retry budget")
  func reenableAfterExhaustedRecoveryStartsFreshRetryBudget() async throws {
    let defaults = try isolatedRecoveryDefaults()
    defaults.defaults.set(true, forKey: HarnessMonitorMCPPreferencesDefaults.registryHostEnabledKey)
    defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }

    let notificationCenter = NotificationCenter()
    let clock = TestClock()
    let degradedState = HarnessMonitorMCPRuntimeState.degraded(
      socketPath: "/tmp/mcp.sock",
      reason: "listener bind failed"
    )
    let service = RecoveryStubMCPService(
      nextEnabledRuntimeStates: [
        degradedState,
        degradedState,
        .healthy(socketPath: "/tmp/mcp.sock"),
      ]
    )
    let controller = HarnessMonitorMCPStartupController(
      service: service,
      defaults: defaults.defaults,
      notificationCenter: notificationCenter,
      recoveryPolicy: HarnessMonitorMCPRecoveryPolicy(
        maximumRetryCount: 1,
        retryDelay: .seconds(5),
        healthCheckInterval: nil
      ),
      forceEnable: { false },
      sleep: clock.sleep(for:)
    )

    controller.start()
    await waitForCondition {
      controller.recoveryStatus
        == HarnessMonitorMCPRecoveryStatus(
          completedRetryCount: 0,
          maximumRetryCount: 1,
          nextRetryDelay: .seconds(5)
        )
    }
    await clock.advance(by: .seconds(5))
    await waitForCondition {
      controller.recoveryStatus
        == HarnessMonitorMCPRecoveryStatus(
          completedRetryCount: 1,
          maximumRetryCount: 1,
          nextRetryDelay: nil
        )
    }

    #expect(controller.runtimeState == degradedState)
    #expect(
      controller.recoveryStatus
        == HarnessMonitorMCPRecoveryStatus(
          completedRetryCount: 1,
          maximumRetryCount: 1,
          nextRetryDelay: nil
        )
    )

    defaults.defaults.set(
      false,
      forKey: HarnessMonitorMCPPreferencesDefaults.registryHostEnabledKey
    )
    notificationCenter.post(name: UserDefaults.didChangeNotification, object: defaults.defaults)
    await waitForCondition {
      controller.runtimeState == HarnessMonitorMCPRuntimeState.disabled
    }

    defaults.defaults.set(true, forKey: HarnessMonitorMCPPreferencesDefaults.registryHostEnabledKey)
    notificationCenter.post(name: UserDefaults.didChangeNotification, object: defaults.defaults)
    await waitForCondition {
      service.recordedEnabledStates == [true, true, false, true]
        && controller.runtimeState
          == HarnessMonitorMCPRuntimeState.healthy(socketPath: "/tmp/mcp.sock")
    }

    #expect(service.recordedEnabledStates == [true, true, false, true])
    #expect(
      controller.runtimeState
        == HarnessMonitorMCPRuntimeState.healthy(socketPath: "/tmp/mcp.sock")
    )
    #expect(controller.recoveryStatus == nil)

    await controller.stop()
  }
}
