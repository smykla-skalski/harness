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
  case invalidManifest(String)
  case daemonOffline
  case daemonDidNotStart
  case externalDaemonOffline(manifestPath: String)
  case externalDaemonManifestStale(manifestPath: String)
  case commandFailed(String)

  public var errorDescription: String? {
    switch self {
    case .harnessBinaryNotFound:
      "Unable to locate the bundled harness daemon helper."
    case .manifestMissing:
      "The harness daemon manifest is missing."
    case .manifestUnreadable:
      "The harness daemon manifest could not be read."
    case .invalidManifest(let message):
      "The harness daemon manifest failed trust validation: \(message)"
    case .daemonOffline:
      "The harness daemon is offline. Start the daemon to load live sessions."
    case .daemonDidNotStart:
      "The harness daemon did not become healthy before the timeout."
    case .externalDaemonOffline(let manifestPath):
      "External daemon not running. Start it in a terminal: `harness daemon dev`. "
        + "Manifest expected at \(manifestPath)."
    case .externalDaemonManifestStale(let manifestPath):
      "Stale manifest detected at \(manifestPath). The external daemon exited "
        + "without cleanup. Restart it with `harness daemon dev` in a terminal."
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

private struct ManagedStaleManifestTracker {
  private var signature: String?
  private var firstObservedAt: ContinuousClock.Instant?

  mutating func reset() {
    signature = nil
    firstObservedAt = nil
  }

  mutating func expired(
    signature: String,
    now: ContinuousClock.Instant,
    gracePeriod: Duration
  ) -> Bool {
    if self.signature != signature {
      self.signature = signature
      firstObservedAt = now
      return false
    }

    guard let firstObservedAt else {
      self.firstObservedAt = now
      return false
    }

    return now - firstObservedAt >= gracePeriod
  }
}

public struct DaemonController: DaemonControlling {
  private static let managedStaleManifestGracePeriod: Duration = .seconds(5)

  private let environment: HarnessMonitorEnvironment
  private let sessionFactory:
    @Sendable (HarnessMonitorConnection) -> any HarnessMonitorClientProtocol
  private let transportPreference: TransportPreference
  private let launchAgentManager: any DaemonLaunchAgentManaging
  private let ownership: DaemonOwnership
  private let endpointProbe: @Sendable (URL) async -> Bool
  private let managedStaleManifestGracePeriod: Duration

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
    managedStaleManifestGracePeriod: Duration = .seconds(5)
  ) {
    self.environment = environment
    self.transportPreference = transportPreference
    self.launchAgentManager = launchAgentManager
    self.ownership = ownership
    self.sessionFactory = sessionFactory
    self.endpointProbe = endpointProbe
    self.managedStaleManifestGracePeriod = managedStaleManifestGracePeriod
  }

  public func bootstrapClient() async throws -> any HarnessMonitorClientProtocol {
    HarnessMonitorLogger.lifecycle.trace(
      "Bootstrapping daemon client for \(String(describing: ownership), privacy: .public) daemon mode"
    )
    let connection = try loadConnection()
    return try await bootstrap(connection: connection)
  }

  private func loadConnection() throws -> HarnessMonitorConnection {
    try connection(from: loadManifest())
  }

  private func bootstrap(
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
    HarnessMonitorLogger.lifecycle.trace(
      "Waiting up to \(String(describing: timeout), privacy: .public) for daemon manifest warm-up"
    )
    let deadline = ContinuousClock.now + timeout
    var lastError: (any Error)?
    var sawUnreachableManifest = false
    var immediateError: (any Error)?
    var managedStaleManifestTracker = ManagedStaleManifestTracker()
    while ContinuousClock.now < deadline {
      do {
        let manifest = try loadManifest()
        let connection = try connection(from: manifest)
        HarnessMonitorLogger.lifecycle.trace(
          "Warm-up observed manifest pid=\(manifest.pid, privacy: .public) endpoint=\(connection.endpoint.absoluteString, privacy: .public)"
        )
        if await endpointProbe(connection.endpoint) {
          HarnessMonitorLogger.lifecycle.trace(
            "Warm-up confirmed live daemon endpoint \(connection.endpoint.absoluteString, privacy: .public)"
          )
          return try await bootstrap(connection: connection)
        }
        let manifestPath = HarnessMonitorPaths.manifestURL(using: environment).path
        HarnessMonitorLogger.lifecycle.error(
          "Warm-up found stale daemon manifest at \(manifestPath, privacy: .public) for endpoint \(connection.endpoint.absoluteString, privacy: .public)"
        )
        if ownership == .external {
          immediateError = DaemonControlError.externalDaemonManifestStale(
            manifestPath: manifestPath
          )
          sawUnreachableManifest = true
          break
        } else {
          lastError = DaemonControlError.daemonDidNotStart
          let staleSignature = Self.managedStaleManifestSignature(for: manifest)
          if managedStaleManifestTracker.expired(
            signature: staleSignature,
            now: ContinuousClock.now,
            gracePeriod: managedStaleManifestGracePeriod
          ) {
            HarnessMonitorLogger.lifecycle.error(
              "Warm-up aborting managed stale manifest wait at \(manifestPath, privacy: .public) after \(String(describing: managedStaleManifestGracePeriod), privacy: .public)"
            )
            break
          }
          HarnessMonitorLogger.lifecycle.trace(
            "Warm-up waiting for managed daemon to rewrite stale manifest at \(manifestPath, privacy: .public)"
          )
        }
        sawUnreachableManifest = true
      } catch let error as DaemonControlError {
        managedStaleManifestTracker.reset()
        if case .invalidManifest = error, ownership == .external {
          immediateError = error
          break
        }
        lastError = error
        HarnessMonitorLogger.lifecycle.trace(
          "Warm-up retry after \(error.localizedDescription, privacy: .public)"
        )
      } catch {
        managedStaleManifestTracker.reset()
        lastError = error
        HarnessMonitorLogger.lifecycle.trace(
          "Warm-up retry after \(error.localizedDescription, privacy: .public)"
        )
      }
      try await Task.sleep(for: .milliseconds(250))
    }
    if let immediateError {
      throw immediateError
    }
    if let client = try? await bootstrapClient() {
      return client
    }
    if ownership == .external {
      let manifestPath = HarnessMonitorPaths.manifestURL(using: environment).path
      if sawUnreachableManifest {
        // Manifest existed throughout the warm-up but nothing bound to its
        // endpoint. Classic crash-without-cleanup: SIGKILL'd dev daemon.
        throw DaemonControlError.externalDaemonManifestStale(manifestPath: manifestPath)
      }
      // No manifest ever appeared; the dev daemon was never started.
      throw DaemonControlError.externalDaemonOffline(manifestPath: manifestPath)
    }
    throw lastError ?? DaemonControlError.daemonDidNotStart
  }

  private func connection(from manifest: DaemonManifest) throws -> HarnessMonitorConnection {
    let endpoint = try endpointURL(from: manifest.endpoint)
    let token = try loadToken(path: manifest.tokenPath)
    return HarnessMonitorConnection(endpoint: endpoint, token: token)
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

  private static func managedStaleManifestSignature(for manifest: DaemonManifest) -> String {
    "\(manifest.pid)|\(manifest.endpoint)|\(manifest.startedAt)"
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

    let manifest = try makeDecoder().decode(DaemonManifest.self, from: data)
    HarnessMonitorLogger.lifecycle.trace(
      "Loaded daemon manifest from \(manifestURL.path, privacy: .public) for pid \(manifest.pid, privacy: .public)"
    )
    return manifest
  }

  private func loadToken(path: String) throws -> String {
    let tokenURL = try validatedTokenURL(from: path)
    let token = try String(contentsOf: tokenURL, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    HarnessMonitorLogger.lifecycle.trace(
      "Loaded daemon auth token from \(tokenURL.path, privacy: .public)"
    )
    return token
  }

  private func endpointURL(from value: String) throws -> URL {
    guard let url = URL(string: value) else {
      throw HarnessMonitorAPIError.invalidEndpoint(value)
    }
    guard ownership != .managed || Self.isTrustedManagedEndpoint(url) else {
      throw DaemonControlError.invalidManifest(
        "managed daemon endpoints must use loopback http(s): \(value)"
      )
    }
    return url
  }

  private func validatedTokenURL(from path: String) throws -> URL {
    guard (path as NSString).isAbsolutePath else {
      throw DaemonControlError.invalidManifest("token path must be absolute")
    }

    let tokenURL = URL(fileURLWithPath: path).standardizedFileURL
    let resolvedTokenURL = tokenURL.resolvingSymlinksInPath()
    guard tokenURL.path == resolvedTokenURL.path else {
      throw DaemonControlError.invalidManifest("token path must not include symlinks")
    }

    let daemonRoot = HarnessMonitorPaths.daemonRoot(using: environment)
      .standardizedFileURL
      .resolvingSymlinksInPath()
    guard Self.isWithinDirectory(resolvedTokenURL, root: daemonRoot) else {
      throw DaemonControlError.invalidManifest(
        "token path must stay inside \(daemonRoot.path)"
      )
    }

    let attributes = try FileManager.default.attributesOfItem(atPath: resolvedTokenURL.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular else {
      throw DaemonControlError.invalidManifest("token path must reference a regular file")
    }
    guard
      let ownerID = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value,
      ownerID == getuid()
    else {
      throw DaemonControlError.invalidManifest("token file must be owned by the current user")
    }
    let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    guard permissions & 0o077 == 0 else {
      throw DaemonControlError.invalidManifest(
        "token file permissions must not grant group or world access"
      )
    }
    return resolvedTokenURL
  }

  private static func isTrustedManagedEndpoint(_ url: URL) -> Bool {
    guard
      let scheme = url.scheme?.lowercased(),
      ["http", "https"].contains(scheme),
      let host = url.host?.lowercased(),
      url.user == nil,
      url.password == nil
    else {
      return false
    }
    return [
      "127.0.0.1",
      "::1",
      "0:0:0:0:0:0:0:1",
      "localhost",
    ].contains(host)
  }

  private static func isWithinDirectory(_ fileURL: URL, root: URL) -> Bool {
    let rootPath = root.path.hasSuffix("/") ? String(root.path.dropLast()) : root.path
    let filePath = fileURL.path
    return filePath == rootPath || filePath.hasPrefix(rootPath + "/")
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
