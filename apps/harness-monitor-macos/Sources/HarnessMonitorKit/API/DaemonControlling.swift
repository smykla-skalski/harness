import Foundation

public protocol DaemonControlling: Sendable {
  func bootstrapClient() async throws -> any HarnessMonitorClientProtocol
  func stopDaemon() async throws -> String
  func daemonStatus() async throws -> DaemonStatusReport
  func installLaunchAgent() async throws -> String
  func removeLaunchAgent() async throws -> String
  func registerLaunchAgent() async throws -> DaemonLaunchAgentRegistrationState
  func repairLaunchAgentRegistration() async throws -> String
  func refreshManagedLaunchAgentForLaunch() async throws -> Bool
  func launchAgentRegistrationState() async -> DaemonLaunchAgentRegistrationState
  func launchAgentSnapshot() async -> LaunchAgentStatus
  func awaitLaunchAgentState(
    _ target: DaemonLaunchAgentRegistrationState,
    timeout: Duration
  ) async throws
  func awaitManifestWarmUp(
    timeout: Duration
  ) async throws -> any HarnessMonitorClientProtocol
  func performDeferredManagedLaunchAgentRefreshIfNeeded() async -> Bool
}

extension DaemonControlling {
  public func refreshManagedLaunchAgentForLaunch() async throws -> Bool {
    false
  }
}
