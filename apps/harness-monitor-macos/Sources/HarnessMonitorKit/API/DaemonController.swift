import Darwin
import Foundation
import ServiceManagement

public protocol DaemonControlling: Sendable {
  func bootstrapClient() async throws -> any HarnessMonitorClientProtocol
  func stopDaemon() async throws -> String
  func daemonStatus() async throws -> DaemonStatusReport
  func installLaunchAgent() async throws -> String
  func removeLaunchAgent() async throws -> String
  func registerLaunchAgent() async throws -> DaemonLaunchAgentRegistrationState
  func launchAgentRegistrationState() async -> DaemonLaunchAgentRegistrationState
  func launchAgentSnapshot() async -> LaunchAgentStatus
  func awaitLaunchAgentState(
    _ target: DaemonLaunchAgentRegistrationState,
    timeout: Duration
  ) async throws
  func awaitManifestWarmUp(
    timeout: Duration
  ) async throws -> any HarnessMonitorClientProtocol
}

public struct DaemonController: DaemonControlling {
  private static let managedStaleManifestDefaultGracePeriod: Duration = .seconds(5)

  let environment: HarnessMonitorEnvironment
  let sessionFactory: @Sendable (HarnessMonitorConnection) -> any HarnessMonitorClientProtocol
  let transportPreference: TransportPreference
  let launchAgentManager: any DaemonLaunchAgentManaging
  let ownership: DaemonOwnership
  let endpointProbe: @Sendable (URL) async -> Bool
  let managedStaleManifestGracePeriod: Duration
  let expectedManagedDaemonVersion: @Sendable () -> String?
  let managedLaunchAgentCurrentBundleStamp: @Sendable () throws -> ManagedLaunchAgentBundleStamp?

  public init(
    environment: HarnessMonitorEnvironment = .current,
    transportPreference: TransportPreference = .auto,
    launchAgentManager: any DaemonLaunchAgentManaging =
      ServiceManagementDaemonLaunchAgentManager(),
    ownership: DaemonOwnership = .managed,
    sessionFactory:
      @escaping @Sendable (HarnessMonitorConnection) -> any HarnessMonitorClientProtocol = {
        HarnessMonitorAPIClient(connection: $0)
      },
    endpointProbe: @escaping @Sendable (URL) async -> Bool = {
      await Self.defaultEndpointProbe($0)
    },
    managedStaleManifestGracePeriod: Duration = .seconds(5),
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
      }
  ) {
    self.environment = environment
    self.transportPreference = transportPreference
    self.launchAgentManager = launchAgentManager
    self.ownership = ownership
    self.sessionFactory = sessionFactory
    self.endpointProbe = endpointProbe
    self.managedStaleManifestGracePeriod = managedStaleManifestGracePeriod
    self.expectedManagedDaemonVersion = expectedManagedDaemonVersion
    self.managedLaunchAgentCurrentBundleStamp = managedLaunchAgentCurrentBundleStamp
  }

  public func bootstrapClient() async throws -> any HarnessMonitorClientProtocol {
    HarnessMonitorLogger.lifecycle.trace(
      "Bootstrapping daemon client for \(String(describing: ownership), privacy: .public) daemon mode"
    )
    let connection = try loadConnection()
    return try await bootstrap(connection: connection)
  }

  func loadConnection() throws -> HarnessMonitorConnection {
    try daemonConnection(from: loadManifest())
  }

  func bootstrap(
    connection: HarnessMonitorConnection
  ) async throws -> any HarnessMonitorClientProtocol {
    HarnessMonitorLogger.lifecycle.trace(
      "Probing daemon health over HTTP at \(connection.endpoint.absoluteString, privacy: .public)"
    )
    let httpClient = sessionFactory(connection)
    _ = try await httpClient.health()

    if transportPreference != .http {
      if let wsClient = try? await bootstrapWebSocket(connection: connection) {
        HarnessMonitorLogger.lifecycle.trace(
          "Upgraded daemon transport to WebSocket for \(connection.endpoint.absoluteString, privacy: .public)"
        )
        return wsClient
      }
      if transportPreference == .webSocket {
        throw DaemonControlError.commandFailed("WebSocket connection failed")
      }
    }

    return httpClient
  }

  func bootstrapWebSocket(
    connection: HarnessMonitorConnection
  ) async throws -> WebSocketTransport {
    let transport = WebSocketTransport(connection: connection)
    do {
      try await transport.connect()
      _ = try await transport.health()
      return transport
    } catch {
      await transport.shutdown()
      throw error
    }
  }

  public func registerLaunchAgent() async throws -> DaemonLaunchAgentRegistrationState {
    try launchAgentManager.register()
    let state = launchAgentManager.registrationState()
    if state == .enabled {
      try persistCurrentManagedLaunchAgentBundleStamp()
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
      .appendingPathComponent("harness")
    guard FileManager.default.fileExists(atPath: helperURL.path) else {
      return nil
    }
    return try ManagedLaunchAgentBundleStamp(helperURL: helperURL)
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
