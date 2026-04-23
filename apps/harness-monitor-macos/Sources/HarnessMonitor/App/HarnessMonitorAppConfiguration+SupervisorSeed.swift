#if DEBUG
  import HarnessMonitorKit

  extension HarnessMonitorAppConfiguration {
    private static let supervisorSeedEnvKey = "HARNESS_MONITOR_SUPERVISOR_SEED_SNAPSHOT"

    @MainActor
    static func seedSupervisorScenario(
      environment: HarnessMonitorEnvironment,
      store: HarnessMonitorStore
    ) {
      store.seedSupervisorScenarioForTesting(
        named: environment.values[supervisorSeedEnvKey]
      )
    }
  }
#endif
