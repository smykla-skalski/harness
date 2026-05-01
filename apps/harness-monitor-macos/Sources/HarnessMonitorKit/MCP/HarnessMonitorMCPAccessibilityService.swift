import Foundation
import HarnessMonitorRegistry
import OSLog

public enum HarnessMonitorMCPRuntimeState: Equatable, Sendable {
  case disabled
  case starting(socketPath: String?)
  case healthy(socketPath: String)
  case degraded(socketPath: String?, reason: String)

  public var socketPath: String? {
    switch self {
    case .disabled:
      nil
    case .starting(let socketPath):
      socketPath
    case .healthy(let socketPath):
      socketPath
    case .degraded(let socketPath, _):
      socketPath
    }
  }

  public var reason: String? {
    switch self {
    case .degraded(_, let reason):
      reason
    case .disabled, .starting, .healthy:
      nil
    }
  }
}

@MainActor
public protocol HarnessMonitorMCPStartupControlling: AnyObject {
  var runtimeState: HarnessMonitorMCPRuntimeState { get }
  func setEnabled(_ enabled: Bool) async
  func probeRuntimeState() async -> HarnessMonitorMCPRuntimeState
}

/// Owns the in-app accessibility registry and its NDJSON Unix-socket
/// listener. The listener stays off until `setEnabled(true)` is called so
/// the app introduces no socket surface by default.
///
/// The service is intentionally a simple reference type instead of a
/// SwiftUI observable: a startup controller owns its lifecycle, and it does
/// not drive any UI.
@MainActor
public final class HarnessMonitorMCPAccessibilityService: HarnessMonitorMCPStartupControlling {
  public static let shared = HarnessMonitorMCPAccessibilityService()

  public let registry: AccessibilityRegistry
  let logger: Logger
  let socketPathResolver: @Sendable () -> URL?
  let pingInfoProvider: @Sendable () -> PingResult
  let startupAttempts: Int
  let startupProbeDelay: Duration
  let startupProbeCount: Int
  let socketClient: RegistrySocketClient
  var listener: RegistryListener?
  var runningSocketURL: URL?
  var remoteSocketURL: URL?
  var pendingReplacementNotice: RegistryReplacementNotice?
  // The listener only yields after the replacement ack flushes. Track the
  // accepted notice with a monotonic generation so late callbacks from an old
  // lifecycle cannot resurrect remote mode after disable or recovery.
  var acknowledgedReplacement: AcknowledgedReplacement?
  var replacementRecoveryTask: Task<Void, Never>?
  var replacementGeneration: UInt64 = 0
  public private(set) var runtimeState: HarnessMonitorMCPRuntimeState = .disabled
  enum ReplacementDecision {
    case approved
    case denied(String)
  }
  struct AcknowledgedReplacement: Equatable {
    let notice: RegistryReplacementNotice
    let generation: UInt64
  }
  // Coordinated replacement is a two-phase handoff: the old host acknowledges the
  // notice, the listener flushes that ack, and only then does the old host yield
  // and republish into the replacement socket. That keeps the wire contract
  // load-bearing instead of optimistic.
  lazy var dispatcher = RegistryRequestDispatcher(
    registry: self.registry,
    pingInfo: self.pingInfoProvider,
    replacementHandler: { [weak self] notice in
      guard let self else {
        return RegistryRequestDispatcher.ReplacementDisposition(
          ack: RegistryAckResult(applied: false, message: "registry service released")
        )
      }
      return await self.handleReplacementNotice(notice)
    }
  )

  public init(
    registry: AccessibilityRegistry = AccessibilityRegistry(),
    logger: Logger = Logger(subsystem: "io.harnessmonitor", category: "mcp-registry"),
    socketPathResolver: @escaping @Sendable () -> URL? = { HarnessMonitorMCPSocketPath.resolved() },
    pingInfoProvider: (@Sendable () -> PingResult)? = nil,
    startupAttempts: Int = 3,
    startupProbeDelay: Duration = .milliseconds(50),
    startupProbeCount: Int = 20,
    socketClient: RegistrySocketClient = RegistrySocketClient()
  ) {
    let pingInfoProvider = pingInfoProvider ?? Self.makePingInfoProvider()
    self.registry = registry
    self.logger = logger
    self.socketPathResolver = socketPathResolver
    self.pingInfoProvider = pingInfoProvider
    self.startupAttempts = max(1, startupAttempts)
    self.startupProbeDelay = startupProbeDelay
    self.startupProbeCount = max(1, startupProbeCount)
    self.socketClient = socketClient
  }

  /// Whether the listener is currently bound to its socket.
  public var isRunning: Bool {
    listener != nil
  }

  /// Start or stop the registry host to match `enabled`. Safe to call
  /// repeatedly with the same value.
  public func setEnabled(_ enabled: Bool) async {
    if enabled {
      await startIfNeeded()
    } else {
      await stop()
    }
  }

  public func probeRuntimeState() async -> HarnessMonitorMCPRuntimeState {
    guard let socket = activeSocketURL ?? socketPathResolver() else {
      return .degraded(socketPath: nil, reason: "cannot resolve app-group container")
    }
    guard listener != nil || remoteSocketURL != nil else {
      return .disabled
    }
    guard let pingInfo = await pingSocket(at: socket.path) else {
      let reason =
        if pendingReplacementNotice != nil {
          "waiting for the replacement registry host to appear"
        } else if remoteSocketURL != nil {
          "connected registry host failed the local ping probe"
        } else {
          "listener failed the local ping probe"
        }
      return .degraded(socketPath: socket.path, reason: reason)
    }
    if listener != nil, sameHost(lhs: pingInfo, rhs: localPingInfo) {
      return .healthy(socketPath: socket.path)
    }
    guard isCompatible(remoteHost: pingInfo, localHost: localPingInfo) else {
      return .degraded(
        socketPath: socket.path,
        reason: incompatibilityReason(remoteHost: pingInfo, localHost: localPingInfo)
      )
    }
    return .healthy(socketPath: socket.path)
  }

  var activeSocketURL: URL? {
    if listener != nil {
      return runningSocketURL
    }
    return remoteSocketURL
  }

  var localPingInfo: PingResult {
    pingInfoProvider()
  }

  var requiredRemoteCapabilities: Set<RegistryCapability> {
    [.clientSnapshots, .clientSnapshotLeases]
  }

  func startIfNeeded() async {
    guard let socket = resolvedSocketForStartup() else {
      return
    }
    if await reconcileExistingLocalListener(at: socket) {
      return
    }
    if await reuseCompatibleRemoteHost(at: socket) {
      return
    }
    if await resumePendingReplacementIfNeeded(at: socket) {
      return
    }
    if await evaluateExistingHostReplacement(at: socket) == false {
      return
    }
    await startLocalListener(at: socket)
  }

  func stop() async {
    let hadOwnedListener = listener != nil
    let reusedRemoteSocket = remoteSocketURL
    replacementRecoveryTask?.cancel()
    replacementRecoveryTask = nil
    pendingReplacementNotice = nil
    acknowledgedReplacement = nil
    replacementGeneration &+= 1
    await stopListener()
    remoteSocketURL = nil
    await registry.setRemoteSocketPath(nil)

    if hadOwnedListener == false,
      reusedRemoteSocket == nil,
      let socketURL = socketPathResolver(),
      await pingSocket(at: socketURL.path) == nil
    {
      cleanupSocketFileIfPresent(at: socketURL)
    }
    runtimeState = .disabled
  }

  func stopListener() async {
    guard let listener else {
      runningSocketURL = nil
      return
    }
    await listener.stop()
    self.listener = nil
    if let socketURL = runningSocketURL {
      logger.trace(
        "harness-monitor MCP: registry host stopped at \(socketURL.path, privacy: .public)"
      )
      runningSocketURL = nil
    }
  }

  func resolvedSocketForStartup() -> URL? {
    guard let socket = remoteSocketURL ?? socketPathResolver() else {
      runtimeState = .degraded(
        socketPath: nil,
        reason: "cannot resolve app-group container"
      )
      logger.error(
        "harness-monitor MCP: cannot resolve app-group container; host not started"
      )
      return nil
    }
    return socket
  }

  func reconcileExistingLocalListener(at socket: URL) async -> Bool {
    guard listener != nil, let pingInfo = await pingSocket(at: socket.path) else {
      return false
    }
    guard sameHost(lhs: pingInfo, rhs: localPingInfo) else {
      return false
    }
    await registry.setRemoteSocketPath(nil)
    remoteSocketURL = nil
    pendingReplacementNotice = nil
    acknowledgedReplacement = nil
    runtimeState = .healthy(socketPath: socket.path)
    return true
  }

  func reuseCompatibleRemoteHost(at socket: URL) async -> Bool {
    if remoteSocketURL != nil,
      let pingInfo = await pingSocket(at: socket.path),
      isCompatible(remoteHost: pingInfo, localHost: localPingInfo)
    {
      runtimeState = .healthy(socketPath: socket.path)
      return true
    }
    return false
  }

  func resumePendingReplacementIfNeeded(at socket: URL) async -> Bool {
    guard pendingReplacementNotice != nil else {
      return false
    }
    runtimeState = .starting(socketPath: socket.path)
    if await waitForCompatibleRemoteHost(at: socket.path) {
      await attachToRemoteHost(at: socket)
    }
    return true
  }

  func evaluateExistingHostReplacement(at socket: URL) async -> Bool {
    guard let remoteHost = await pingSocket(at: socket.path) else {
      return true
    }
    if isCompatible(remoteHost: remoteHost, localHost: localPingInfo) {
      await attachToRemoteHost(at: socket)
      return false
    }
    guard shouldReplace(remoteHost: remoteHost, localHost: localPingInfo) else {
      let reason = incompatibilityReason(remoteHost: remoteHost, localHost: localPingInfo)
      runtimeState = .degraded(socketPath: socket.path, reason: reason)
      logger.error(
        """
        MCP start refused to replace existing socket at \(socket.path, privacy: .public): \
        \(reason, privacy: .public)
        """
      )
      return false
    }
    switch await requestReplacement(of: remoteHost, at: socket) {
    case .approved:
      return true
    case .denied(let reason):
      runtimeState = .degraded(socketPath: socket.path, reason: reason)
      logger.error(
        """
        MCP start refused to replace existing socket at \(socket.path, privacy: .public): \
        \(reason, privacy: .public)
        """
      )
      return false
    }
  }

  func startLocalListener(at socket: URL) async {
    await registry.setRemoteSocketPath(nil)
    remoteSocketURL = nil
    acknowledgedReplacement = nil
    await stopListener()
    runtimeState = .starting(socketPath: socket.path)

    for attempt in 1...startupAttempts {
      let nextListener = RegistryListener(dispatcher: dispatcher, logger: logger)
      do {
        try await nextListener.start(at: socket.path, replaceExistingSocketFile: true)
      } catch {
        let description = error.localizedDescription
        logger.error(
          """
          MCP start failed at \(socket.path, privacy: .public) \
          on attempt \(attempt, privacy: .public): \(description, privacy: .public)
          """
        )
        runtimeState = .degraded(socketPath: socket.path, reason: description)
        cleanupSocketFileIfPresent(at: socket)
        continue
      }

      listener = nextListener
      runningSocketURL = socket

      if await waitForMatchingHost(at: socket.path, expectedHost: localPingInfo) {
        runtimeState = .healthy(socketPath: socket.path)
        pendingReplacementNotice = nil
        acknowledgedReplacement = nil
        logger.trace(
          "harness-monitor MCP: registry host started at \(socket.path, privacy: .public)"
        )
        return
      }

      logger.error(
        """
        MCP listener never passed the local ping probe at \
        \(socket.path, privacy: .public) on attempt \(attempt, privacy: .public)
        """
      )
      await stopListener()
    }

    runtimeState = .degraded(
      socketPath: socket.path,
      reason: "listener never passed the local ping probe"
    )
  }
}
