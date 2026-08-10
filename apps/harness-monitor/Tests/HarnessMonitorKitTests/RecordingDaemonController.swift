import Foundation

@testable import HarnessMonitorKit

actor RecordingDaemonController: DaemonControlling {
  enum BootstrapOutcome: Sendable {
    case success(any HarnessMonitorClientProtocol)
    case failure(any Error)
  }

  private let client: any HarnessMonitorClientProtocol
  private var bootstrapOutcomes: [BootstrapOutcome]
  private var launchAgentInstalled: Bool
  private var registrationStateOverride: DaemonLaunchAgentRegistrationState?
  private let statusReportOverride: DaemonStatusReport?
  private let bootstrapError: (any Error)?
  private let bootstrapChecksCancellation: Bool
  private let registerLaunchAgentHandler: (@Sendable () async throws -> Void)?
  private let warmUpError: (any Error)?
  private let warmUpHandler: (@Sendable () async throws -> any HarnessMonitorClientProtocol)?
  private let deferredManagedLaunchAgentRefreshResult: Bool
  private var legacyCleanupError: (any Error)?
  private let legacyCleanupHandler: (@Sendable () async throws -> Void)?
  private var lastEventMessage = "daemon ready"
  private var registerLaunchAgentCallCount = 0
  private var warmUpCallCount = 0
  private var stopDaemonCallCount = 0
  private var deferredRefreshCallCount = 0
  private var bootstrapCallCount = 0
  private var launchAgentStateCallCount = 0
  private var legacyCleanupCallCount = 0

  init(
    client: any HarnessMonitorClientProtocol = PreviewHarnessClient(),
    bootstrapOutcomes: [BootstrapOutcome] = [],
    launchAgentInstalled: Bool = true,
    registrationState: DaemonLaunchAgentRegistrationState? = nil,
    statusReport: DaemonStatusReport? = nil,
    bootstrapError: (any Error)? = nil,
    bootstrapChecksCancellation: Bool = false,
    registerLaunchAgentHandler: (@Sendable () async throws -> Void)? = nil,
    warmUpError: (any Error)? = nil,
    warmUpHandler:
      (@Sendable () async throws -> any HarnessMonitorClientProtocol)? = nil,
    usesWarmUpErrorForBootstrap: Bool = true,
    deferredManagedLaunchAgentRefreshResult: Bool = false,
    legacyCleanupError: (any Error)? = nil,
    legacyCleanupHandler: (@Sendable () async throws -> Void)? = nil
  ) {
    self.client = client
    self.bootstrapOutcomes = bootstrapOutcomes
    self.launchAgentInstalled = launchAgentInstalled
    self.registrationStateOverride = registrationState
    self.statusReportOverride = statusReport
    self.bootstrapError = bootstrapError ?? (usesWarmUpErrorForBootstrap ? warmUpError : nil)
    self.bootstrapChecksCancellation = bootstrapChecksCancellation
    self.registerLaunchAgentHandler = registerLaunchAgentHandler
    self.warmUpError = warmUpError
    self.warmUpHandler = warmUpHandler
    self.deferredManagedLaunchAgentRefreshResult = deferredManagedLaunchAgentRefreshResult
    self.legacyCleanupError = legacyCleanupError
    self.legacyCleanupHandler = legacyCleanupHandler
  }

  func bootstrapClient() async throws -> any HarnessMonitorClientProtocol {
    bootstrapCallCount += 1
    if bootstrapChecksCancellation {
      try Task.checkCancellation()
    }
    if !bootstrapOutcomes.isEmpty {
      switch bootstrapOutcomes.removeFirst() {
      case .success(let client):
        return client
      case .failure(let error):
        throw error
      }
    }
    if let bootstrapError {
      throw bootstrapError
    }
    return client
  }

  func registerLaunchAgent() async throws -> DaemonLaunchAgentRegistrationState {
    registerLaunchAgentCallCount += 1
    try await registerLaunchAgentHandler?()
    launchAgentInstalled = true
    registrationStateOverride = .enabled
    lastEventMessage = "launch agent installed"
    return .enabled
  }

  func launchAgentRegistrationState() async -> DaemonLaunchAgentRegistrationState {
    launchAgentStateCallCount += 1
    if let registrationStateOverride {
      return registrationStateOverride
    }
    return launchAgentInstalled ? .enabled : .notRegistered
  }

  func launchAgentSnapshot() async -> LaunchAgentStatus {
    LaunchAgentStatus(
      installed: launchAgentInstalled,
      loaded: launchAgentInstalled,
      label: "io.harness.daemon",
      path: "/tmp/io.harness.daemon.plist",
      domainTarget: "gui/501",
      serviceTarget: "gui/501/io.harness.daemon",
      state: launchAgentInstalled ? "running" : nil,
      pid: launchAgentInstalled ? 4_242 : nil,
      lastExitStatus: launchAgentInstalled ? 0 : nil
    )
  }

  func awaitLaunchAgentState(
    _ target: DaemonLaunchAgentRegistrationState,
    timeout: Duration
  ) async throws {}

  func awaitManifestWarmUp(
    timeout: Duration
  ) async throws -> any HarnessMonitorClientProtocol {
    warmUpCallCount += 1
    if let warmUpHandler {
      return try await warmUpHandler()
    }
    if let warmUpError {
      throw warmUpError
    }
    return client
  }

  func performDeferredManagedLaunchAgentRefreshIfNeeded() async -> Bool {
    deferredRefreshCallCount += 1
    return deferredManagedLaunchAgentRefreshResult
  }

  func requireLegacyManagedLaunchAgentCleanup() async throws {
    legacyCleanupCallCount += 1
    if let legacyCleanupHandler {
      try await legacyCleanupHandler()
      return
    }
    if let legacyCleanupError {
      throw legacyCleanupError
    }
  }

  func setLegacyCleanupError(_ error: (any Error)?) {
    legacyCleanupError = error
  }

  func stopDaemon() async throws -> String {
    stopDaemonCallCount += 1
    lastEventMessage = "daemon stopped"
    return "stopped"
  }

  func daemonStatus() async throws -> DaemonStatusReport {
    if let statusReportOverride {
      return statusReportOverride
    }
    return DaemonStatusReport(
      manifest: DaemonManifest(
        version: "14.5.0",
        pid: 111,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-03-28T14:00:00Z",
        tokenPath: "/tmp/token"
      ),
      launchAgent: LaunchAgentStatus(
        installed: launchAgentInstalled,
        loaded: launchAgentInstalled,
        label: "io.harness.daemon",
        path: "/tmp/io.harness.daemon.plist",
        domainTarget: "gui/501",
        serviceTarget: "gui/501/io.harness.daemon",
        state: launchAgentInstalled ? "running" : nil,
        pid: launchAgentInstalled ? 4_242 : nil,
        lastExitStatus: launchAgentInstalled ? 0 : nil
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
        databaseSizeBytes: 1_740_800,
        lastEvent: DaemonAuditEvent(
          recordedAt: "2026-03-28T14:00:00Z",
          level: "info",
          message: lastEventMessage
        )
      )
    )
  }

  func installLaunchAgent() async throws -> String {
    launchAgentInstalled = true
    lastEventMessage = "launch agent installed"
    return "/tmp/io.harness.daemon.plist"
  }

  func removeLaunchAgent() async throws -> String {
    launchAgentInstalled = false
    lastEventMessage = "launch agent removed"
    return "removed"
  }

  func repairLaunchAgentRegistration() async throws -> String {
    launchAgentInstalled = true
    lastEventMessage = "launch agent re-registered"
    return "launch agent re-registered"
  }

  func recordedRegisterLaunchAgentCallCount() async -> Int {
    registerLaunchAgentCallCount
  }

  func recordedWarmUpCallCount() async -> Int {
    warmUpCallCount
  }

  func recordedStopDaemonCallCount() async -> Int {
    stopDaemonCallCount
  }

  func recordedDeferredManagedLaunchAgentRefreshCallCount() async -> Int {
    deferredRefreshCallCount
  }

  func recordedBootstrapCallCount() async -> Int {
    bootstrapCallCount
  }

  func recordedLaunchAgentStateCallCount() async -> Int {
    launchAgentStateCallCount
  }

  func recordedLegacyCleanupCallCount() async -> Int {
    legacyCleanupCallCount
  }
}
