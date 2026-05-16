import Darwin
import Foundation
import ServiceManagement

public struct DaemonController: DaemonControlling {
  private static let managedStaleManifestDefaultGracePeriod: Duration = .seconds(5)

  private enum AutoTransportBootstrapOutcome: Sendable {
    case upgraded(any HarnessMonitorClientProtocol)
    case unavailable
    case timedOut
  }

  let environment: HarnessMonitorEnvironment
  let sessionFactory: @Sendable (HarnessMonitorConnection) -> any HarnessMonitorClientProtocol
  let webSocketBootstrapper:
    @Sendable (HarnessMonitorConnection) async -> (any HarnessMonitorClientProtocol)?
  let transportPreference: TransportPreference
  let autoTransportWebSocketGracePeriod: Duration
  let launchAgentManager: any DaemonLaunchAgentManaging
  let ownership: DaemonOwnership
  let endpointProbe: @Sendable (URL) async -> Bool
  let managedStaleManifestGracePeriod: Duration
  let warmUpBackoff: WarmUpBackoff
  let expectedManagedDaemonVersion: @Sendable () -> String?
  let managedLaunchAgentCurrentBundleStamp: @Sendable () throws -> ManagedLaunchAgentBundleStamp?
  let managedLaunchAgentDeferredRefreshState: ManagedLaunchAgentDeferredRefreshState
  let processLiveness: ProcessLivenessProbe
  let bootSessionUUID: BootSessionUUIDProbe
  let externalManifestLocator: ExternalDaemonManifestLocator

  public init(
    environment: HarnessMonitorEnvironment = .current,
    transportPreference: TransportPreference = .webSocket,
    launchAgentManager: any DaemonLaunchAgentManaging =
      ServiceManagementDaemonLaunchAgentManager(),
    ownership: DaemonOwnership = .managed,
    autoTransportWebSocketGracePeriod: Duration = .seconds(2),
    sessionFactory:
      @escaping @Sendable (HarnessMonitorConnection) -> any HarnessMonitorClientProtocol = {
        HarnessMonitorAPIClient(connection: $0)
      },
    webSocketBootstrapper:
      @escaping @Sendable (HarnessMonitorConnection) async
      -> (any HarnessMonitorClientProtocol)? = {
        let transport = WebSocketTransport(connection: $0)
        do {
          try await transport.connect()
          _ = try await transport.health()
          return transport
        } catch {
          await transport.shutdown()
          return nil
        }
      },
    endpointProbe: @escaping @Sendable (URL) async -> Bool = {
      await Self.defaultEndpointProbe($0)
    },
    managedStaleManifestGracePeriod: Duration = .seconds(5),
    warmUpBackoff: WarmUpBackoff = .default,
    expectedManagedDaemonVersion: @escaping @Sendable () -> String? = {
      guard
        let bundleIdentifier = Bundle.main.bundleIdentifier,
        bundleIdentifier == "io.harnessmonitor.app"
          || bundleIdentifier == "io.harnessmonitor.app.ui-testing"
      else {
        return nil
      }

      return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    },
    managedLaunchAgentCurrentBundleStamp:
      @escaping @Sendable () throws
      -> ManagedLaunchAgentBundleStamp? = {
        try Self.currentManagedLaunchAgentBundleStamp()
      },
    processLiveness: @escaping ProcessLivenessProbe = Self.defaultProcessLiveness,
    bootSessionUUID: @escaping BootSessionUUIDProbe = Self.defaultBootSessionUUID,
    externalManifestDefaults: UserDefaults = .standard
  ) {
    self.environment = environment
    self.transportPreference = transportPreference
    self.autoTransportWebSocketGracePeriod = autoTransportWebSocketGracePeriod
    self.launchAgentManager = launchAgentManager
    self.ownership = ownership
    self.sessionFactory = sessionFactory
    self.webSocketBootstrapper = webSocketBootstrapper
    self.endpointProbe = endpointProbe
    self.managedStaleManifestGracePeriod = managedStaleManifestGracePeriod
    self.warmUpBackoff = warmUpBackoff
    self.expectedManagedDaemonVersion = expectedManagedDaemonVersion
    self.managedLaunchAgentCurrentBundleStamp = managedLaunchAgentCurrentBundleStamp
    self.managedLaunchAgentDeferredRefreshState = ManagedLaunchAgentDeferredRefreshState()
    self.processLiveness = processLiveness
    self.bootSessionUUID = bootSessionUUID
    self.externalManifestLocator = ExternalDaemonManifestLocator(
      environment: environment,
      ownership: ownership,
      defaults: externalManifestDefaults
    )
  }

  public func bootstrapClient() async throws -> any HarnessMonitorClientProtocol {
    HarnessMonitorLogger.lifecycle.trace(
      "Bootstrapping daemon client for \(String(describing: ownership), privacy: .public) daemon mode"
    )
    let connection = try loadConnection()
    let client = try await bootstrap(connection: connection)
    externalManifestLocator.rememberActiveManifestIfNeeded()
    return client
  }

  public func performDeferredManagedLaunchAgentRefreshIfNeeded() async -> Bool {
    guard let currentStamp = await managedLaunchAgentDeferredRefreshState.takePending() else {
      return false
    }
    do {
      HarnessMonitorLogger.lifecycle.notice(
        "Applying deferred managed daemon helper refresh while startup-critical work is idle"
      )
      switch try refreshManagedLaunchAgent(currentStamp: currentStamp) {
      case .refreshed:
        return true
      case .skippedSiblingOwnsLane, .skippedNotManagedDaemon, .skippedLockContended:
        return false
      }
    } catch {
      HarnessMonitorLogger.lifecycle.error(
        "Deferred managed daemon helper refresh failed: \(error.localizedDescription, privacy: .public)"
      )
      return false
    }
  }

  func loadConnection() throws -> HarnessMonitorConnection {
    try daemonConnection(from: loadManifest())
  }

  func bootstrap(
    connection: HarnessMonitorConnection
  ) async throws -> any HarnessMonitorClientProtocol {
    if transportPreference == .webSocket {
      if let wsClient = await webSocketBootstrapper(connection) {
        let endpoint = connection.endpoint.absoluteString
        HarnessMonitorLogger.lifecycle.trace(
          "Connected daemon transport over WebSocket for \(endpoint, privacy: .public)"
        )
        return wsClient
      }
      throw DaemonControlError.commandFailed("WebSocket connection failed")
    }

    HarnessMonitorLogger.lifecycle.trace(
      "Probing daemon health over HTTP at \(connection.endpoint.absoluteString, privacy: .public)"
    )
    let httpClient = sessionFactory(connection)
    _ = try await httpClient.health()
    guard transportPreference != .http else {
      return httpClient
    }

    if transportPreference == .auto {
      switch await bootstrapAutoTransport(connection: connection) {
      case .upgraded(let wsClient):
        await httpClient.shutdown()
        HarnessMonitorLogger.lifecycle.trace(
          "Upgraded daemon transport to WebSocket for \(connection.endpoint.absoluteString, privacy: .public)"
        )
        return wsClient
      case .timedOut:
        let gracePeriod = String(describing: autoTransportWebSocketGracePeriod)
        HarnessMonitorLogger.lifecycle.info(
          """
          HTTP bootstrap is healthy; continuing startup on HTTP/SSE after \
          WebSocket upgrade exceeded \(gracePeriod, privacy: .public)
          """
        )
      case .unavailable:
        break
      }
      return httpClient
    }

    if let wsClient = await webSocketBootstrapper(connection) {
      await httpClient.shutdown()
      HarnessMonitorLogger.lifecycle.trace(
        "Upgraded daemon transport to WebSocket for \(connection.endpoint.absoluteString, privacy: .public)"
      )
      return wsClient
    }
    throw DaemonControlError.commandFailed("WebSocket connection failed")
  }

  private func bootstrapAutoTransport(
    connection: HarnessMonitorConnection
  ) async -> AutoTransportBootstrapOutcome {
    await withTaskGroup(
      of: AutoTransportBootstrapOutcome.self,
      returning: AutoTransportBootstrapOutcome.self
    ) { group in
      group.addTask {
        if let wsClient = await webSocketBootstrapper(connection) {
          return .upgraded(wsClient)
        }
        return .unavailable
      }
      let gracePeriod = autoTransportWebSocketGracePeriod
      group.addTask {
        try? await Task.sleep(for: gracePeriod)
        return .timedOut
      }

      let outcome = await group.next() ?? .unavailable
      group.cancelAll()
      return outcome
    }
  }

  public func registerLaunchAgent() async throws -> DaemonLaunchAgentRegistrationState {
    try launchAgentManager.register()
    let state = launchAgentManager.registrationState()
    if state == .enabled {
      try persistCurrentManagedLaunchAgentBundleStamp()
      try persistCurrentManagedLaunchAgentOwner()
    }
    return state
  }

  public func launchAgentRegistrationState() async -> DaemonLaunchAgentRegistrationState {
    launchAgentManager.registrationState()
  }

  public func launchAgentSnapshot() async -> LaunchAgentStatus {
    launchAgentStatus()
  }

  public func awaitLaunchAgentState(
    _ target: DaemonLaunchAgentRegistrationState,
    timeout: Duration
  ) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if launchAgentManager.registrationState() == target {
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    if launchAgentManager.registrationState() == target {
      return
    }
    throw DaemonControlError.daemonDidNotStart
  }

  public func stopDaemon() async throws -> String {
    if launchAgentManager.registrationState() == .enabled {
      try launchAgentManager.unregister()
      clearManagedLaunchAgentBundleStamp()
      clearManagedLaunchAgentOwner()
      return "stopped"
    }

    let client = try await bootstrapClient()
    let response = try await client.stopDaemon()
    return response.status
  }

  public func daemonStatus() async throws -> DaemonStatusReport {
    let launchAgent = launchAgentStatus()
    let client = try await bootstrapClient()
    defer {
      Task.detached { await client.shutdown() }
    }
    let report = try await client.diagnostics()
    return DaemonStatusReport(diagnosticsReport: report)
      .replacingLaunchAgentStatus(launchAgent)
  }

  public func installLaunchAgent() async throws -> String {
    if ownership == .external {
      throw DaemonControlError.commandFailed(
        "Install Launch Agent is disabled in external daemon mode. "
          + "Stop the dev daemon or unset HARNESS_MONITOR_EXTERNAL_DAEMON to install."
      )
    }
    switch launchAgentManager.registrationState() {
    case .enabled:
      return "launch agent already installed"
    case .requiresApproval:
      throw DaemonControlError.commandFailed(
        "Enable Harness Monitor daemon in System Settings > General > Login Items."
      )
    case .notRegistered, .notFound:
      switch try await registerLaunchAgent() {
      case .enabled:
        return "launch agent installed"
      case .requiresApproval:
        return "launch agent registered; approval required in System Settings"
      case .notRegistered, .notFound:
        throw DaemonControlError.commandFailed("launch agent registration did not complete")
      }
    }
  }

  public func removeLaunchAgent() async throws -> String {
    if ownership == .external {
      throw DaemonControlError.commandFailed(
        "Remove Launch Agent is disabled in external daemon mode."
      )
    }
    switch launchAgentManager.registrationState() {
    case .notRegistered, .notFound:
      return "launch agent not installed"
    case .enabled, .requiresApproval:
      try launchAgentManager.unregister()
      clearManagedLaunchAgentBundleStamp()
      clearManagedLaunchAgentOwner()
      return "launch agent removed"
    }
  }

  /// Tear down and re-register the bundled SMAppService launch agent at app
  /// launch so each session starts with a fresh BTM disposition record and
  /// a fresh Launch Constraint Record. Recovers transparently from the
  /// `xpcproxy exit(78)` / `Unable to get updated LWCR` crash loops that
  /// appear after Xcode rebuilds shift the helper's `cs_mtime` without
  /// triggering BTM to re-validate. No-op in `.external` ownership so the
  /// `harness daemon dev` flow is unaffected.
  ///
  /// Returns `true` if a refresh actually happened, `false` if skipped
  /// (external mode or registration not present).
  public func refreshManagedLaunchAgentForLaunch() async throws -> Bool {
    guard ownership == .managed else {
      return false
    }
    let preState = launchAgentManager.registrationState()
    switch preState {
    case .enabled, .requiresApproval:
      try launchAgentManager.unregister()
      clearManagedLaunchAgentBundleStamp()
      clearManagedLaunchAgentOwner()
      // BTM needs a moment after `unregister()` to evict the prior
      // disposition record; without this delay the immediate `register()`
      // can land on a half-cleared row and the next launchd spawn still
      // fails to fetch the updated LWCR.
      try? await Task.sleep(for: .milliseconds(500))
    case .notRegistered, .notFound:
      break
    }
    try launchAgentManager.register()
    let postState = launchAgentManager.registrationState()
    switch postState {
    case .enabled:
      try persistCurrentManagedLaunchAgentBundleStamp()
      try persistCurrentManagedLaunchAgentOwner()
      HarnessMonitorLogger.lifecycle.notice(
        "Refreshed managed launch agent registration on app launch (pre_state=\(String(describing: preState), privacy: .public))"
      )
      return true
    case .requiresApproval:
      HarnessMonitorLogger.lifecycle.notice(
        "Managed launch agent refresh awaiting user approval in System Settings"
      )
      return true
    case .notRegistered, .notFound:
      throw DaemonControlError.commandFailed(
        "launch agent refresh did not complete"
      )
    }
  }

  /// Force re-registration of the SMAppService launch agent to recover from
  /// stale BTM uuid records (xpcproxy `EX_CONFIG` spawn-fail loops). Always
  /// unregisters first, regardless of `ownership`, so external-daemon users
  /// can clean up an orphan managed registration without changing modes.
  /// In `.managed` mode the unregister is followed by a fresh register so
  /// the helper is reachable again on the next launchd spawn cycle.
  public func repairLaunchAgentRegistration() async throws -> String {
    let preState = launchAgentManager.registrationState()
    switch preState {
    case .enabled, .requiresApproval:
      try launchAgentManager.unregister()
      clearManagedLaunchAgentBundleStamp()
      clearManagedLaunchAgentOwner()
    case .notRegistered, .notFound:
      break
    }

    guard ownership == .managed else {
      return preState == .notRegistered || preState == .notFound
        ? "launch agent not registered"
        : "launch agent unregistered"
    }

    try launchAgentManager.register()
    let postState = launchAgentManager.registrationState()
    if postState == .enabled {
      try persistCurrentManagedLaunchAgentBundleStamp()
      try persistCurrentManagedLaunchAgentOwner()
      return "launch agent re-registered"
    }
    if postState == .requiresApproval {
      return "launch agent re-registered; approval required in System Settings"
    }
    throw DaemonControlError.commandFailed(
      "launch agent re-registration did not complete"
    )
  }

  public static func defaultEndpointProbe(_ endpoint: URL) async -> Bool {
    guard let host = endpoint.host, let port = endpoint.port else {
      return true
    }
    let candidate = UInt16(exactly: port) ?? 0
    guard candidate != 0 else { return true }
    return await Task.detached(priority: .userInitiated) {
      DaemonPortProbe.isListening(
        host: host,
        port: candidate,
        timeout: .milliseconds(200)
      )
    }.value
  }

  public static func currentManagedLaunchAgentBundleStamp() throws -> ManagedLaunchAgentBundleStamp?
  {
    let helperURL = Bundle.main.bundleURL
      .appendingPathComponent("Contents", isDirectory: true)
      .appendingPathComponent("Helpers", isDirectory: true)
      .appendingPathComponent("harness")
    guard FileManager.default.fileExists(atPath: helperURL.path) else {
      return nil
    }
    let launchAgentPlistURL = Bundle.main.bundleURL
      .appendingPathComponent(HarnessMonitorPaths.launchAgentBundleRelativePath)
    return try ManagedLaunchAgentBundleStamp(
      helperURL: helperURL,
      launchAgentPlistURL: launchAgentPlistURL
    )
  }

  func managedDaemonVersionMismatch(for manifest: DaemonManifest) -> DaemonControlError? {
    guard ownership == .managed else {
      return nil
    }

    guard
      let expectedVersion = expectedManagedDaemonVersion()?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !expectedVersion.isEmpty,
      manifest.version != expectedVersion
    else {
      return nil
    }

    return .managedDaemonVersionMismatch(expected: expectedVersion, actual: manifest.version)
  }
}
