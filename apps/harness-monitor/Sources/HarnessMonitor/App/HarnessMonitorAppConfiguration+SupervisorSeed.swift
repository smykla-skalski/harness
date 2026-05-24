#if DEBUG
  import HarnessMonitorKit

  extension HarnessMonitorAppConfiguration {
    private static let supervisorSeedEnvKey = "HARNESS_MONITOR_SUPERVISOR_SEED_SNAPSHOT"

    @MainActor
    static func seedSupervisorScenario(
      environment: HarnessMonitorEnvironment,
      store: HarnessMonitorStore
    ) {
      let scenarioName = environment.values[supervisorSeedEnvKey]
      Task { @MainActor in
        await store.seedSupervisorScenarioForTesting(named: scenarioName)
      }
    }
  }
#endif
