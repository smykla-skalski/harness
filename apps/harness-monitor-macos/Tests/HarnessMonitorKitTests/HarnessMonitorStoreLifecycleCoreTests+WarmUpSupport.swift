import Foundation

@testable import HarnessMonitorKit

actor BootstrapBarrierDaemonController: DaemonControlling {
  private let base: RecordingDaemonController
  private var warmUpStarted = false
  private var warmUpStartedContinuation: CheckedContinuation<Void, Never>?
  private var warmUpReleaseContinuation: CheckedContinuation<Void, Never>?
  private var warmUpCallCount = 0

  init(client: any HarnessMonitorClientProtocol = PreviewHarnessClient()) {
    base = RecordingDaemonController(client: client)
  }

  func bootstrapClient() async throws -> any HarnessMonitorClientProtocol {
    try await base.bootstrapClient()
  }

  func stopDaemon() async throws -> String {
    try await base.stopDaemon()
  }

  func daemonStatus() async throws -> DaemonStatusReport {
    try await base.daemonStatus()
  }

  func installLaunchAgent() async throws -> String {
    try await base.installLaunchAgent()
  }

  func removeLaunchAgent() async throws -> String {
    try await base.removeLaunchAgent()
  }

  func registerLaunchAgent() async throws -> DaemonLaunchAgentRegistrationState {
    try await base.registerLaunchAgent()
  }

  func repairLaunchAgentRegistration() async throws -> String {
    try await base.repairLaunchAgentRegistration()
  }

  func launchAgentRegistrationState() async -> DaemonLaunchAgentRegistrationState {
    await base.launchAgentRegistrationState()
  }

  func launchAgentSnapshot() async -> LaunchAgentStatus {
    await base.launchAgentSnapshot()
  }

  func awaitLaunchAgentState(
    _ target: DaemonLaunchAgentRegistrationState,
    timeout: Duration
  ) async throws {
    try await base.awaitLaunchAgentState(target, timeout: timeout)
  }

  func awaitManifestWarmUp(
    timeout: Duration
  ) async throws -> any HarnessMonitorClientProtocol {
    _ = timeout
    warmUpCallCount += 1
    warmUpStarted = true
    warmUpStartedContinuation?.resume()
    warmUpStartedContinuation = nil
    await withCheckedContinuation { continuation in
      warmUpReleaseContinuation = continuation
    }
    return try await base.awaitManifestWarmUp(timeout: timeout)
  }

  func performDeferredManagedLaunchAgentRefreshIfNeeded() async -> Bool {
    await base.performDeferredManagedLaunchAgentRefreshIfNeeded()
  }

  func waitUntilWarmUpStarted() async {
    guard !warmUpStarted else {
      return
    }
    await withCheckedContinuation { continuation in
      warmUpStartedContinuation = continuation
    }
  }

  func releaseWarmUp() {
    warmUpReleaseContinuation?.resume()
    warmUpReleaseContinuation = nil
  }

  func recordedWarmUpCallCount() -> Int {
    warmUpCallCount
  }
}

func bootstrapTaskCompletes(
  _ task: Task<Void, Never>,
  timeout: Duration
) async -> Bool {
  await withTaskGroup(of: Bool.self) { group in
    group.addTask {
      await task.value
      return true
    }
    group.addTask {
      try? await Task.sleep(for: timeout)
      return false
    }

    let completed = await group.next() ?? false
    group.cancelAll()
    return completed
  }
}
