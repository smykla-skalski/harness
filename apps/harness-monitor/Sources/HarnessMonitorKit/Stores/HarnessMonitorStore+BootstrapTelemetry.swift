import Foundation

enum HarnessMonitorBootstrapTelemetryPhase: String, Sendable {
  case managedLaunchAgentReady = "managed_launch_agent_ready"
  case managedDaemonWarmUp = "managed_daemon_warm_up"
  case managedLaunchAgentRefreshRecovery = "managed_launch_agent_refresh_recovery"
  case managedInitialConnect = "managed_initial_connect"
  case externalDaemonWarmUp = "external_daemon_warm_up"
  case externalInitialConnect = "external_initial_connect"
  case remoteDaemonConnect = "remote_daemon_connect"
  case remoteInitialConnect = "remote_initial_connect"
}

extension HarnessMonitorStore {
  func withBootstrapTelemetryPhase<T>(
    _ phase: HarnessMonitorBootstrapTelemetryPhase,
    _ operation: () async throws -> T
  ) async rethrows -> T {
    #if HARNESS_FEATURE_OTEL
      return try await HarnessMonitorTelemetry.shared.withBootstrapPhase(
        phase: phase.rawValue,
        launchMode: HarnessMonitorLaunchMode.live.rawValue,
        operation
      )
    #else
      _ = phase
      return try await operation()
    #endif
  }
}
