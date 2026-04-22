import Foundation

@testable import HarnessMonitorKit

actor ManagedWarmUpRecoveryDaemonController: DaemonControlling {
  private let client: any HarnessMonitorClientProtocol
  private var warmUpAttempts = 0
  private var operations: [String] = []

  init(client: any HarnessMonitorClientProtocol = PreviewHarnessClient()) {
    self.client = client
  }

  func bootstrapClient() async throws -> any HarnessMonitorClientProtocol {
    client
  }

  func stopDaemon() async throws -> String {
    "stopped"
  }

  func daemonStatus() async throws -> DaemonStatusReport {
    DaemonStatusReport(
      manifest: DaemonManifest(
        version: "19.4.0",
        pid: 111,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-04-11T14:00:00Z",
        tokenPath: "/tmp/token"
      ),
      launchAgent: LaunchAgentStatus(
        installed: true,
        loaded: true,
        label: "io.harness.daemon",
        path: "/tmp/io.harness.daemon.plist"
      ),
      projectCount: 1,
      sessionCount: 1,
      diagnostics: DaemonDiagnostics(
        daemonRoot: "/tmp/harness/daemon",
        manifestPath: "/tmp/harness/daemon/manifest.json",
        authTokenPath: "/tmp/token",
        authTokenPresent: true,
        eventsPath: "/tmp/harness/daemon/events.jsonl",
        databasePath: "/tmp/harness/daemon/harness.db",
        databaseSizeBytes: 1_024,
        lastEvent: nil
      )
    )
  }

  func installLaunchAgent() async throws -> String {
    "launch agent installed"
  }

  func removeLaunchAgent() async throws -> String {
    operations.append("remove")
    return "launch agent removed"
  }

  func registerLaunchAgent() async throws -> DaemonLaunchAgentRegistrationState {
    operations.append("register")
    return .enabled
  }

  func launchAgentRegistrationState() async -> DaemonLaunchAgentRegistrationState {
    .enabled
  }

  func launchAgentSnapshot() async -> LaunchAgentStatus {
    LaunchAgentStatus(
      installed: true,
      loaded: true,
      label: "io.harness.daemon",
      path: "/tmp/io.harness.daemon.plist"
    )
  }

  func awaitLaunchAgentState(
    _ target: DaemonLaunchAgentRegistrationState,
    timeout: Duration
  ) async throws {}

  func awaitManifestWarmUp(
    timeout: Duration
  ) async throws -> any HarnessMonitorClientProtocol {
    operations.append("warm-up")
    if warmUpAttempts == 0 {
      warmUpAttempts += 1
      throw DaemonControlError.daemonDidNotStart
    }
    return client
  }

  func performDeferredManagedLaunchAgentRefreshIfNeeded() async -> Bool {
    false
  }

  func recordedOperations() -> [String] {
    operations
  }
}

actor ManagedDaemonVersionRecoveryDaemonController: DaemonControlling {
  private let client: any HarnessMonitorClientProtocol
  private var warmUpAttempts = 0
  private var operations: [String] = []

  init(client: any HarnessMonitorClientProtocol = PreviewHarnessClient()) {
    self.client = client
  }

  func bootstrapClient() async throws -> any HarnessMonitorClientProtocol {
    client
  }

  func stopDaemon() async throws -> String {
    "stopped"
  }

  func daemonStatus() async throws -> DaemonStatusReport {
    DaemonStatusReport(
      manifest: DaemonManifest(
        version: "20.6.17",
        pid: 111,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-04-11T14:00:00Z",
        tokenPath: "/tmp/token"
      ),
      launchAgent: LaunchAgentStatus(
        installed: true,
        loaded: true,
        label: "io.harness.daemon",
        path: "/tmp/io.harness.daemon.plist"
      ),
      projectCount: 1,
      sessionCount: 1,
      diagnostics: DaemonDiagnostics(
        daemonRoot: "/tmp/harness/daemon",
        manifestPath: "/tmp/harness/daemon/manifest.json",
        authTokenPath: "/tmp/token",
        authTokenPresent: true,
        eventsPath: "/tmp/harness/daemon/events.jsonl",
        databasePath: "/tmp/harness/daemon/harness.db",
        databaseSizeBytes: 1_024,
        lastEvent: nil
      )
    )
  }

  func installLaunchAgent() async throws -> String {
    "launch agent installed"
  }

  func removeLaunchAgent() async throws -> String {
    operations.append("remove")
    return "launch agent removed"
  }

  func registerLaunchAgent() async throws -> DaemonLaunchAgentRegistrationState {
    operations.append("register")
    return .enabled
  }

  func launchAgentRegistrationState() async -> DaemonLaunchAgentRegistrationState {
    .enabled
  }

  func launchAgentSnapshot() async -> LaunchAgentStatus {
    LaunchAgentStatus(
      installed: true,
      loaded: true,
      label: "io.harness.daemon",
      path: "/tmp/io.harness.daemon.plist"
    )
  }

  func awaitLaunchAgentState(
    _ target: DaemonLaunchAgentRegistrationState,
    timeout: Duration
  ) async throws {}

  func awaitManifestWarmUp(
    timeout: Duration
  ) async throws -> any HarnessMonitorClientProtocol {
    operations.append("warm-up")
    if warmUpAttempts == 0 {
      warmUpAttempts += 1
      throw DaemonControlError.managedDaemonVersionMismatch(
        expected: "20.6.19",
        actual: "20.6.17"
      )
    }
    return client
  }

  func performDeferredManagedLaunchAgentRefreshIfNeeded() async -> Bool {
    false
  }

  func recordedOperations() -> [String] {
    operations
  }
}

actor ManagedLaunchAgentRefreshThrottleDaemonController: DaemonControlling {
  private var operations: [String] = []

  func bootstrapClient() async throws -> any HarnessMonitorClientProtocol {
    throw DaemonControlError.daemonDidNotStart
  }

  func stopDaemon() async throws -> String {
    "stopped"
  }

  func daemonStatus() async throws -> DaemonStatusReport {
    DaemonStatusReport(
      manifest: DaemonManifest(
        version: "21.0.2",
        pid: 111,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-04-14T13:02:00Z",
        tokenPath: "/tmp/token"
      ),
      launchAgent: LaunchAgentStatus(
        installed: true,
        loaded: true,
        label: "io.harness.daemon",
        path: "/tmp/io.harness.daemon.plist"
      ),
      projectCount: 1,
      sessionCount: 1,
      diagnostics: DaemonDiagnostics(
        daemonRoot: "/tmp/harness/daemon",
        manifestPath: "/tmp/harness/daemon/manifest.json",
        authTokenPath: "/tmp/token",
        authTokenPresent: true,
        eventsPath: "/tmp/harness/daemon/events.jsonl",
        databasePath: "/tmp/harness/daemon/harness.db",
        databaseSizeBytes: 1_024,
        lastEvent: nil
      )
    )
  }

  func installLaunchAgent() async throws -> String {
    "launch agent installed"
  }

  func removeLaunchAgent() async throws -> String {
    operations.append("remove")
    return "launch agent removed"
  }

  func registerLaunchAgent() async throws -> DaemonLaunchAgentRegistrationState {
    operations.append("register")
    return .enabled
  }

  func launchAgentRegistrationState() async -> DaemonLaunchAgentRegistrationState {
    .enabled
  }

  func launchAgentSnapshot() async -> LaunchAgentStatus {
    LaunchAgentStatus(
      installed: true,
      loaded: true,
      label: "io.harness.daemon",
      path: "/tmp/io.harness.daemon.plist"
    )
  }

  func awaitLaunchAgentState(
    _ target: DaemonLaunchAgentRegistrationState,
    timeout: Duration
  ) async throws {}

  func awaitManifestWarmUp(
    timeout: Duration
  ) async throws -> any HarnessMonitorClientProtocol {
    operations.append("warm-up")
    throw DaemonControlError.daemonDidNotStart
  }

  func performDeferredManagedLaunchAgentRefreshIfNeeded() async -> Bool {
    false
  }

  func recordedOperations() -> [String] {
    operations
  }
}

actor ManagedWarmUpLateBootstrapDaemonController: DaemonControlling {
  private let client: any HarnessMonitorClientProtocol
  private var operations: [String] = []

  init(client: any HarnessMonitorClientProtocol = PreviewHarnessClient()) {
    self.client = client
  }

  func bootstrapClient() async throws -> any HarnessMonitorClientProtocol {
    operations.append("bootstrap")
    return client
  }

  func stopDaemon() async throws -> String {
    "stopped"
  }

  func daemonStatus() async throws -> DaemonStatusReport {
    DaemonStatusReport(
      manifest: DaemonManifest(
        version: "23.1.0",
        pid: 111,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-04-17T10:22:59Z",
        tokenPath: "/tmp/token"
      ),
      launchAgent: LaunchAgentStatus(
        installed: true,
        loaded: true,
        label: "io.harness.daemon",
        path: "/tmp/io.harness.daemon.plist"
      ),
      projectCount: 1,
      sessionCount: 1,
      diagnostics: DaemonDiagnostics(
        daemonRoot: "/tmp/harness/daemon",
        manifestPath: "/tmp/harness/daemon/manifest.json",
        authTokenPath: "/tmp/token",
        authTokenPresent: true,
        eventsPath: "/tmp/harness/daemon/events.jsonl",
        databasePath: "/tmp/harness/daemon/harness.db",
        databaseSizeBytes: 1_024,
        lastEvent: nil
      )
    )
  }

  func installLaunchAgent() async throws -> String {
    "launch agent installed"
  }

  func removeLaunchAgent() async throws -> String {
    operations.append("remove")
    return "launch agent removed"
  }

  func registerLaunchAgent() async throws -> DaemonLaunchAgentRegistrationState {
    operations.append("register")
    return .enabled
  }

  func launchAgentRegistrationState() async -> DaemonLaunchAgentRegistrationState {
    .enabled
  }

  func launchAgentSnapshot() async -> LaunchAgentStatus {
    LaunchAgentStatus(
      installed: true,
      loaded: true,
      label: "io.harness.daemon",
      path: "/tmp/io.harness.daemon.plist"
    )
  }

  func awaitLaunchAgentState(
    _ target: DaemonLaunchAgentRegistrationState,
    timeout: Duration
  ) async throws {}

  func awaitManifestWarmUp(
    timeout: Duration
  ) async throws -> any HarnessMonitorClientProtocol {
    operations.append("warm-up")
    throw DaemonControlError.daemonDidNotStart
  }

  func performDeferredManagedLaunchAgentRefreshIfNeeded() async -> Bool {
    false
  }

  func recordedOperations() -> [String] {
    operations
  }
}
