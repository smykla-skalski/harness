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

public enum DaemonLaunchAgentRegistrationState: Equatable, Sendable {
  case notRegistered
  case enabled
  case requiresApproval
  case notFound
}

public protocol DaemonLaunchAgentManaging: Sendable {
  func registrationState() -> DaemonLaunchAgentRegistrationState
  func register() throws
  func unregister() throws
}

public struct ServiceManagementDaemonLaunchAgentManager: DaemonLaunchAgentManaging {
  private let plistName: String

  public init(plistName: String = HarnessMonitorPaths.launchAgentPlistName) {
    self.plistName = plistName
  }

  public func registrationState() -> DaemonLaunchAgentRegistrationState {
    switch service.status {
    case .notRegistered:
      .notRegistered
    case .enabled:
      .enabled
    case .requiresApproval:
      .requiresApproval
    case .notFound:
      .notFound
    @unknown default:
      .notFound
    }
  }

  public func register() throws {
    try service.register()
  }

  public func unregister() throws {
    try service.unregister()
  }

  private var service: SMAppService {
    SMAppService.agent(plistName: plistName)
  }
}

public enum DaemonControlError: Error, LocalizedError, Equatable {
  case harnessBinaryNotFound
  case manifestMissing
  case manifestUnreadable
  case daemonOffline
  case daemonDidNotStart
  case commandFailed(String)

  public var errorDescription: String? {
    switch self {
    case .harnessBinaryNotFound:
      "Unable to locate the bundled harness daemon helper."
    case .manifestMissing:
      "The harness daemon manifest is missing."
    case .manifestUnreadable:
      "The harness daemon manifest could not be read."
    case .daemonOffline:
      "The harness daemon is offline. Start the daemon to load live sessions."
    case .daemonDidNotStart:
      "The harness daemon did not become healthy before the timeout."
    case .commandFailed(let message):
      message
    }
  }
}

public enum TransportPreference: Sendable {
  case auto
  case webSocket
  case http
}

public struct DaemonController: DaemonControlling {
  private let environment: HarnessMonitorEnvironment
  private let sessionFactory:
    @Sendable (HarnessMonitorConnection) -> any HarnessMonitorClientProtocol
  private let transportPreference: TransportPreference
  private let launchAgentManager: any DaemonLaunchAgentManaging

  public init(
    environment: HarnessMonitorEnvironment = .current,
    transportPreference: TransportPreference = .auto,
    launchAgentManager: any DaemonLaunchAgentManaging =
      ServiceManagementDaemonLaunchAgentManager(),
    sessionFactory:
      @escaping @Sendable (HarnessMonitorConnection) -> any HarnessMonitorClientProtocol = {
        HarnessMonitorAPIClient(connection: $0)
      }
  ) {
    self.environment = environment
    self.transportPreference = transportPreference
    self.launchAgentManager = launchAgentManager
    self.sessionFactory = sessionFactory
  }

  public func bootstrapClient() async throws -> any HarnessMonitorClientProtocol {
    HarnessMonitorLogger.lifecycle.info("Bootstrapping daemon client")
    let manifest = try loadManifest()
    let token = try loadToken(path: manifest.tokenPath)
    let connection = HarnessMonitorConnection(
      endpoint: try endpointURL(from: manifest.endpoint),
      token: token
    )

    let httpClient = sessionFactory(connection)
    _ = try await httpClient.health()

    if transportPreference != .http {
      if let wsClient = try? await bootstrapWebSocket(connection: connection) {
        return wsClient
      }
      if transportPreference == .webSocket {
        throw DaemonControlError.commandFailed("WebSocket connection failed")
      }
    }

    return httpClient
  }

  private func bootstrapWebSocket(
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
    return launchAgentManager.registrationState()
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

  public func awaitManifestWarmUp(
    timeout: Duration
  ) async throws -> any HarnessMonitorClientProtocol {
    let deadline = ContinuousClock.now + timeout
    var lastError: (any Error)?
    while ContinuousClock.now < deadline {
      do {
        return try await bootstrapClient()
      } catch {
        lastError = error
        try await Task.sleep(for: .milliseconds(250))
      }
    }
    if let client = try? await bootstrapClient() {
      return client
    }
    throw lastError ?? DaemonControlError.daemonDidNotStart
  }

  public func stopDaemon() async throws -> String {
    if launchAgentManager.registrationState() == .enabled {
      try launchAgentManager.unregister()
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
    switch launchAgentManager.registrationState() {
    case .notRegistered, .notFound:
      return "launch agent not installed"
    case .enabled, .requiresApproval:
      try launchAgentManager.unregister()
      return "launch agent removed"
    }
  }

  private func loadManifest() throws -> DaemonManifest {
    let manifestURL = HarnessMonitorPaths.manifestURL(using: environment)
    guard FileManager.default.fileExists(atPath: manifestURL.path) else {
      throw DaemonControlError.manifestMissing
    }

    guard let data = FileManager.default.contents(atPath: manifestURL.path) else {
      throw DaemonControlError.manifestUnreadable
    }

    return try makeDecoder().decode(DaemonManifest.self, from: data)
  }

  private func loadToken(path: String) throws -> String {
    let tokenURL = URL(fileURLWithPath: path)
    return try String(contentsOf: tokenURL, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func endpointURL(from value: String) throws -> URL {
    guard let url = URL(string: value) else {
      throw HarnessMonitorAPIError.invalidEndpoint(value)
    }
    return url
  }

  private func launchAgentStatus() -> LaunchAgentStatus {
    switch launchAgentManager.registrationState() {
    case .enabled:
      LaunchAgentStatus(
        installed: true,
        loaded: true,
        label: "io.harnessmonitor.daemon",
        path: HarnessMonitorPaths.launchAgentBundleRelativePath,
        serviceTarget: "io.harnessmonitor.daemon",
        state: "enabled"
      )
    case .requiresApproval:
      LaunchAgentStatus(
        installed: true,
        loaded: false,
        label: "io.harnessmonitor.daemon",
        path: HarnessMonitorPaths.launchAgentBundleRelativePath,
        serviceTarget: "io.harnessmonitor.daemon",
        statusError: "Approval required in System Settings > General > Login Items"
      )
    case .notRegistered:
      LaunchAgentStatus(
        installed: false,
        loaded: false,
        label: "io.harnessmonitor.daemon",
        path: HarnessMonitorPaths.launchAgentBundleRelativePath,
        serviceTarget: "io.harnessmonitor.daemon"
      )
    case .notFound:
      LaunchAgentStatus(
        installed: false,
        loaded: false,
        label: "io.harnessmonitor.daemon",
        path: HarnessMonitorPaths.launchAgentBundleRelativePath,
        serviceTarget: "io.harnessmonitor.daemon",
        statusError: "Bundled daemon launch agent plist was not found"
      )
    }
  }

  private func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }
}

extension DaemonStatusReport {
  fileprivate func replacingLaunchAgentStatus(
    _ launchAgent: LaunchAgentStatus
  ) -> DaemonStatusReport {
    DaemonStatusReport(
      manifest: manifest,
      launchAgent: launchAgent,
      projectCount: projectCount,
      worktreeCount: worktreeCount,
      sessionCount: sessionCount,
      diagnostics: diagnostics
    )
  }
}

