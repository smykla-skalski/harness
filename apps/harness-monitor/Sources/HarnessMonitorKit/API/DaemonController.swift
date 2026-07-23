import Darwin
import Foundation
import ServiceManagement

public struct DaemonController: DaemonControlling {
  static let managedStaleManifestDefaultGracePeriod: Duration = .seconds(5)
  public static let managedLaunchAgentBTMSettleDelayDefault: Duration = .milliseconds(500)

  let environment: HarnessMonitorEnvironment
  let sessionFactory: @Sendable (HarnessMonitorConnection) -> any HarnessMonitorClientProtocol
  let webSocketBootstrapper:
    @Sendable (HarnessMonitorConnection) async -> (any HarnessMonitorClientProtocol)?
  let transportPreference: TransportPreference
  let autoTransportWebSocketGracePeriod: Duration
  let launchAgentManager: any DaemonLaunchAgentManaging
  let ownership: DaemonOwnership
  let remoteConnectionSource: any RemoteDaemonConnectionSourcing
  let endpointProbe: @Sendable (URL) async -> Bool
  let managedStaleManifestGracePeriod: Duration
  let managedLaunchAgentBTMSettleDelay: Duration
  let managedLaunchAgentBTMSettleSleep: @Sendable (Duration) async throws -> Void
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
    remoteConnectionSource: (any RemoteDaemonConnectionSourcing)? = nil,
    autoTransportWebSocketGracePeriod: Duration = .seconds(2),
    sessionFactory:
      @escaping @Sendable (HarnessMonitorConnection) -> any HarnessMonitorClientProtocol = {
        HarnessMonitorAPIClient(connection: $0)
      },
    webSocketBootstrapper:
      @escaping @Sendable (HarnessMonitorConnection) async
      -> (any HarnessMonitorClientProtocol)? = {
        await Self.defaultWebSocketBootstrap($0)
      },
    endpointProbe: @escaping @Sendable (URL) async -> Bool = {
      await Self.defaultEndpointProbe($0)
    },
    managedStaleManifestGracePeriod: Duration = .seconds(5),
    managedLaunchAgentBTMSettleDelay: Duration =
      Self.managedLaunchAgentBTMSettleDelayDefault,
    managedLaunchAgentBTMSettleSleep:
      @escaping @Sendable (Duration) async throws -> Void = {
        try await Task.sleep(for: $0)
      },
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
    self.remoteConnectionSource =
      remoteConnectionSource ?? DisabledRemoteDaemonConnectionSource()
    self.sessionFactory = sessionFactory
    self.webSocketBootstrapper = webSocketBootstrapper
    self.endpointProbe = endpointProbe
    self.managedStaleManifestGracePeriod = managedStaleManifestGracePeriod
    self.managedLaunchAgentBTMSettleDelay = managedLaunchAgentBTMSettleDelay
    self.managedLaunchAgentBTMSettleSleep = managedLaunchAgentBTMSettleSleep
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
    do {
      let client = try await bootstrap(connection: connection)
      if !connection.isRemote {
        externalManifestLocator.rememberActiveManifestIfNeeded()
      }
      return client
    } catch {
      handleRemoteAuthorizationFailure(error, connection: connection)
      throw error
    }
  }

  public func performDeferredManagedLaunchAgentRefreshIfNeeded() async -> Bool {
    guard let currentStamp = await managedLaunchAgentDeferredRefreshState.takePending() else {
      return false
    }
    do {
      HarnessMonitorLogger.lifecycle.notice(
        "Applying deferred managed daemon helper refresh while startup-critical work is idle"
      )
      switch try await refreshManagedLaunchAgent(currentStamp: currentStamp) {
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
    let remoteConnection = try loadRemoteStateRecoveringCorruptMetadata {
      try remoteConnectionSource.activeConnection()
    }
    if let remoteConnection {
      return remoteConnection
    }
    return try daemonConnection(from: loadManifest())
  }

  func bootstrap(
    connection: HarnessMonitorConnection
  ) async throws -> any HarnessMonitorClientProtocol {
    if connection.isRemote {
      return try await bootstrapRemoteConnection(connection)
    }
    if transportPreference == .webSocket {
      if let wsClient = await webSocketBootstrapper(connection) {
        let endpoint = connection.endpoint.absoluteString
        HarnessMonitorLogger.lifecycle.trace(
          "Connected daemon transport over WebSocket for \(endpoint, privacy: .public)"
        )
        return wsClient
      }
      // A cancelled attempt also reports nil. Surfacing that as a connection
      // failure would make callers toast an offline banner and schedule a
      // reconnect for work they themselves called off.
      try Task.checkCancellation()
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
        try await requireNotCancelled(releasing: wsClient)
        return wsClient
      case .timedOut:
        let gracePeriod = String(describing: autoTransportWebSocketGracePeriod)
        HarnessMonitorLogger.lifecycle.info(
          """
          HTTP bootstrap is healthy; continuing startup on HTTP/SSE after \
          WebSocket upgrade exceeded \(gracePeriod, privacy: .public)
          """
        )
      case .unavailable, .cancelled:
        break
      }
      try await requireNotCancelled(releasing: httpClient)
      return httpClient
    }

    if let wsClient = await webSocketBootstrapper(connection) {
      await httpClient.shutdown()
      HarnessMonitorLogger.lifecycle.trace(
        "Upgraded daemon transport to WebSocket for \(connection.endpoint.absoluteString, privacy: .public)"
      )
      return wsClient
    }
    try Task.checkCancellation()
    throw DaemonControlError.commandFailed("WebSocket connection failed")
  }

  public func registerLaunchAgent() async throws -> DaemonLaunchAgentRegistrationState {
    try requireLocalDaemonControl("Register Launch Agent")
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
    let remoteProfile = try loadRemoteStateRecoveringCorruptMetadata {
      try remoteConnectionSource.activeProfile()
    }
    if remoteProfile != nil {
      let client = try await bootstrapClient()
      return try await requestDaemonStop(using: client)
    }
    if launchAgentManager.registrationState() == .enabled {
      try launchAgentManager.unregister()
      clearManagedLaunchAgentBundleStamp()
      clearManagedLaunchAgentOwner()
      return "stopped"
    }

    let client = try await bootstrapClient()
    return try await requestDaemonStop(using: client)
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
    try requireLocalDaemonControl("Install Launch Agent")
    if ownership == .external {
      throw DaemonControlError.commandFailed(
        "Install Launch Agent is disabled in external daemon mode. "
          + "Stop the dev daemon or unset HARNESS_MONITOR_EXTERNAL_DAEMON to install"
      )
    }
    switch launchAgentManager.registrationState() {
    case .enabled:
      return "launch agent already installed"
    case .requiresApproval:
      throw DaemonControlError.commandFailed(
        "Enable Harness Monitor daemon in System Settings > General > Login Items"
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
    try requireLocalDaemonControl("Remove Launch Agent")
    if ownership == .external {
      throw DaemonControlError.commandFailed(
        "Remove Launch Agent is disabled in external daemon mode"
      )
    }
    switch launchAgentManager.registrationState() {
    case .notRegistered, .notFound:
      return "launch agent not installed"
    case .enabled, .requiresApproval:
      try launchAgentManager.unregister()
      clearManagedLaunchAgentBundleStamp()
      clearManagedLaunchAgentOwner()
      await awaitManagedLaunchAgentBTMSettleAfterUnregister()
      return "launch agent removed"
    }
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
      .appendingPathComponent("harness-daemon")
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
