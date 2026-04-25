import Foundation

extension HarnessMonitorStore {
  func bootstrapBody() async {
    connectionState = .connecting
    #if HARNESS_FEATURE_OTEL
      startResourceMetricsSampling()
      recordActiveTaskGauge()
    #endif
    await startSupervisor()

    isBootstrapping = true
    defer {
      isBootstrapping = false
      replayQueuedReconnectAfterBootstrapIfNeeded()
    }

    switch daemonOwnership {
    case .external:
      await bootstrapExternalDaemon()
    case .managed:
      await bootstrapManagedDaemon()
    }
  }
}
