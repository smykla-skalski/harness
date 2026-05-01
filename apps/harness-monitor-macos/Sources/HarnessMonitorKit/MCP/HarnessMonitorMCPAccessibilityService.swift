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
  private let logger: Logger
  private let socketPathResolver: @Sendable () -> URL?
  private let pingInfoProvider: @Sendable () -> PingResult
  private let startupAttempts: Int
  private let startupProbeDelay: Duration
  private let startupProbeCount: Int
  private let socketClient: RegistrySocketClient
  private var listener: RegistryListener?
  private var runningSocketURL: URL?
  private var remoteSocketURL: URL?
  private var pendingReplacementNotice: RegistryReplacementNotice?
  // The listener only yields after the replacement ack flushes. Track the
  // accepted notice with a monotonic generation so late callbacks from an old
  // lifecycle cannot resurrect remote mode after disable or recovery.
  private var acknowledgedReplacement: AcknowledgedReplacement?
  private var replacementRecoveryTask: Task<Void, Never>?
  private var replacementGeneration: UInt64 = 0
  public private(set) var runtimeState: HarnessMonitorMCPRuntimeState = .disabled
  private enum ReplacementDecision {
    case approved
    case denied(String)
  }
  private struct AcknowledgedReplacement: Equatable {
    let notice: RegistryReplacementNotice
    let generation: UInt64
  }
  // Coordinated replacement is a two-phase handoff: the old host acknowledges the
  // notice, the listener flushes that ack, and only then does the old host yield
  // and republish into the replacement socket. That keeps the wire contract
  // load-bearing instead of optimistic.
  private lazy var dispatcher = RegistryRequestDispatcher(
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

  private var activeSocketURL: URL? {
    if listener != nil {
      return runningSocketURL
    }
    return remoteSocketURL
  }

  private var localPingInfo: PingResult {
    pingInfoProvider()
  }

  private var requiredRemoteCapabilities: Set<RegistryCapability> {
    [.clientSnapshots, .clientSnapshotLeases]
  }

  private func startIfNeeded() async {
    guard let socket = remoteSocketURL ?? socketPathResolver() else {
      runtimeState = .degraded(
        socketPath: nil,
        reason: "cannot resolve app-group container"
      )
      logger.error(
        "harness-monitor MCP: cannot resolve app-group container; host not started"
      )
      return
    }

    if listener != nil, let pingInfo = await pingSocket(at: socket.path) {
      if sameHost(lhs: pingInfo, rhs: localPingInfo) {
        await registry.setRemoteSocketPath(nil)
        remoteSocketURL = nil
        pendingReplacementNotice = nil
        acknowledgedReplacement = nil
        runtimeState = .healthy(socketPath: socket.path)
        return
      }
    }

    if remoteSocketURL != nil,
      let pingInfo = await pingSocket(at: socket.path),
      isCompatible(remoteHost: pingInfo, localHost: localPingInfo)
    {
      runtimeState = .healthy(socketPath: socket.path)
      return
    }

    if pendingReplacementNotice != nil {
      runtimeState = .starting(socketPath: socket.path)
      if await waitForCompatibleRemoteHost(at: socket.path) {
        await attachToRemoteHost(at: socket)
      }
      return
    }

    if let remoteHost = await pingSocket(at: socket.path) {
      if isCompatible(remoteHost: remoteHost, localHost: localPingInfo) {
        await attachToRemoteHost(at: socket)
        return
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
        return
      }
      switch await requestReplacement(of: remoteHost, at: socket) {
      case .approved:
        break
      case .denied(let reason):
        runtimeState = .degraded(socketPath: socket.path, reason: reason)
        logger.error(
          """
          MCP start refused to replace existing socket at \(socket.path, privacy: .public): \
          \(reason, privacy: .public)
          """
        )
        return
      }
    }

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

  private func stop() async {
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

  private func stopListener() async {
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

  private static func makePingInfoProvider() -> @Sendable () -> PingResult {
    let bundle = Bundle.main
    let version =
      (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    let bundleId = bundle.bundleIdentifier ?? "io.harnessmonitor.app"
    let capabilities: [RegistryCapability] = [
      .clientSnapshots,
      .clientSnapshotLeases,
      .replacementNotice,
    ]
    return { @Sendable in
      PingResult(
        protocolVersion: registryProtocolVersion,
        appVersion: version,
        bundleIdentifier: bundleId,
        capabilities: capabilities
      )
    }
  }

  private func waitForCompatibleRemoteHost(at path: String) async -> Bool {
    for _ in 0..<startupProbeCount {
      if let pingInfo = await pingSocket(at: path),
        isCompatible(remoteHost: pingInfo, localHost: localPingInfo)
      {
        return true
      }
      try? await Task.sleep(for: startupProbeDelay)
    }
    return false
  }

  private func waitForMatchingHost(at path: String, expectedHost: PingResult) async -> Bool {
    for _ in 0..<startupProbeCount {
      if let pingInfo = await pingSocket(at: path), sameHost(lhs: pingInfo, rhs: expectedHost) {
        return true
      }
      try? await Task.sleep(for: startupProbeDelay)
    }
    return false
  }

  private func pingSocket(at path: String) async -> PingResult? {
    try? await socketClient.ping(at: path)
  }

  private func attachToRemoteHost(at socket: URL) async {
    replacementRecoveryTask?.cancel()
    replacementRecoveryTask = nil
    await stopListener()
    await registry.setRemoteSocketPath(socket.path)
    remoteSocketURL = socket
    pendingReplacementNotice = nil
    acknowledgedReplacement = nil
    runtimeState = .healthy(socketPath: socket.path)
    logger.trace(
      "harness-monitor MCP: reusing compatible registry host at \(socket.path, privacy: .public)"
    )
  }

  private func requestReplacement(
    of remoteHost: PingResult,
    at socket: URL
  ) async -> ReplacementDecision {
    guard remoteHost.capabilities.contains(.replacementNotice) else {
      return .denied(
        "existing registry host is incompatible and does not support coordinated replacement notices"
      )
    }

    let notice = RegistryReplacementNotice(
      socketPath: socket.path,
      protocolVersion: localPingInfo.protocolVersion,
      appVersion: localPingInfo.appVersion,
      bundleIdentifier: localPingInfo.bundleIdentifier,
      message:
        "A newer Harness Monitor MCP registry host is taking ownership of this socket. "
        + "Stop listening and reregister your windows and elements against the replacement host."
    )

    do {
      let ack = try await socketClient.sendReplacementNotice(notice, toSocketAt: socket.path)
      if ack.applied == false {
        return .denied(
          ack.message ?? "existing registry host rejected coordinated replacement"
        )
      }
      guard await waitForSocketYield(at: socket.path, previousHost: remoteHost) else {
        return .denied("existing registry host acknowledged replacement but never yielded the socket")
      }
      return .approved
    } catch {
      return .denied(
        "failed to notify the existing registry host about replacement: \(error.localizedDescription)"
      )
    }
  }

  private func waitForSocketYield(at path: String, previousHost: PingResult) async -> Bool {
    for _ in 0..<startupProbeCount {
      if let pingInfo = await pingSocket(at: path) {
        if sameHost(lhs: pingInfo, rhs: previousHost) == false {
          return true
        }
      } else {
        return true
      }
      try? await Task.sleep(for: startupProbeDelay)
    }
    return false
  }

  private func handleReplacementNotice(
    _ notice: RegistryReplacementNotice
  ) async -> RegistryRequestDispatcher.ReplacementDisposition {
    let expectedSocketPath = activeSocketURL?.path ?? socketPathResolver()?.path
    guard notice.socketPath == expectedSocketPath else {
      return RegistryRequestDispatcher.ReplacementDisposition(
        ack: RegistryAckResult(
          applied: false,
          message: "replacement notice targeted an unexpected socket path"
        )
      )
    }
    guard shouldYield(to: notice, localHost: localPingInfo) else {
      return RegistryRequestDispatcher.ReplacementDisposition(
        ack: RegistryAckResult(
          applied: false,
          message: "replacement host is not newer than the current registry host"
        )
      )
    }

    replacementGeneration &+= 1
    let generation = replacementGeneration
    acknowledgedReplacement = AcknowledgedReplacement(notice: notice, generation: generation)
    runtimeState = .starting(socketPath: notice.socketPath)
    return RegistryRequestDispatcher.ReplacementDisposition(
      ack: RegistryAckResult(
        applied: true,
        message: "listener acknowledged replacement and will yield after flushing this response"
      ),
      onDelivered: { [weak self] in
        guard let self else {
          return
        }
        await self.finalizeReplacementYield(notice, generation: generation)
      },
      closeConnectionAfterDelivery: true
    )
  }

  private func finalizeReplacementYield(
    _ notice: RegistryReplacementNotice,
    generation: UInt64
  ) async {
    guard acknowledgedReplacement == AcknowledgedReplacement(notice: notice, generation: generation) else {
      return
    }

    acknowledgedReplacement = nil
    pendingReplacementNotice = notice
    replacementRecoveryTask?.cancel()
    replacementRecoveryTask = nil
    await stopListener()
    remoteSocketURL = URL(fileURLWithPath: notice.socketPath)
    await registry.setRemoteSocketPath(notice.socketPath)
    runtimeState = .starting(socketPath: notice.socketPath)
    logger.info(
      """
      harness-monitor MCP: yielding socket ownership to replacement host at \
      \(notice.socketPath, privacy: .public)
      """
    )

    replacementRecoveryTask = Task { [weak self] in
      guard let self else {
        return
      }
      let replacementAppeared = await self.waitForCompatibleRemoteHost(at: notice.socketPath)
      guard Task.isCancelled == false else {
        return
      }
      await self.finishReplacementYieldWait(
        notice: notice,
        replacementAppeared: replacementAppeared
      )
    }
  }

  private func finishReplacementYieldWait(
    notice: RegistryReplacementNotice,
    replacementAppeared: Bool
  ) async {
    guard pendingReplacementNotice == notice else {
      return
    }
    if replacementAppeared {
      await attachToRemoteHost(at: URL(fileURLWithPath: notice.socketPath))
      return
    }

    logger.error(
      """
      harness-monitor MCP: replacement host never appeared at \
      \(notice.socketPath, privacy: .public); reclaiming the registry listener
      """
    )
    pendingReplacementNotice = nil
    remoteSocketURL = nil
    await registry.setRemoteSocketPath(nil)
    await startIfNeeded()
  }

  private func isCompatible(remoteHost: PingResult, localHost: PingResult) -> Bool {
    guard remoteHost.protocolVersion == localHost.protocolVersion else {
      return false
    }
    guard remoteHost.bundleIdentifier == localHost.bundleIdentifier else {
      return false
    }
    return Set(remoteHost.capabilities).isSuperset(of: requiredRemoteCapabilities)
  }

  private func shouldReplace(remoteHost: PingResult, localHost: PingResult) -> Bool {
    guard isCompatible(remoteHost: remoteHost, localHost: localHost) == false else {
      return false
    }
    guard remoteHost.bundleIdentifier == localHost.bundleIdentifier else {
      return false
    }
    if remoteHost.protocolVersion < localHost.protocolVersion {
      return true
    }
    if remoteHost.protocolVersion > localHost.protocolVersion {
      return false
    }
    return compareVersions(remoteHost.appVersion, localHost.appVersion) != .orderedDescending
  }

  private func shouldYield(
    to replacementNotice: RegistryReplacementNotice,
    localHost: PingResult
  ) -> Bool {
    guard replacementNotice.bundleIdentifier == localHost.bundleIdentifier else {
      return false
    }
    if replacementNotice.protocolVersion > localHost.protocolVersion {
      return true
    }
    if replacementNotice.protocolVersion < localHost.protocolVersion {
      return false
    }
    return compareVersions(replacementNotice.appVersion, localHost.appVersion) != .orderedAscending
  }

  private func incompatibilityReason(remoteHost: PingResult, localHost: PingResult) -> String {
    if remoteHost.bundleIdentifier != localHost.bundleIdentifier {
      return
        "existing registry host belongs to \(remoteHost.bundleIdentifier), not "
        + "\(localHost.bundleIdentifier)"
    }
    if remoteHost.protocolVersion > localHost.protocolVersion {
      return
        "existing registry host uses protocol \(remoteHost.protocolVersion), newer than local "
        + "protocol \(localHost.protocolVersion)"
    }
    if remoteHost.protocolVersion < localHost.protocolVersion {
      return
        "existing registry host uses protocol \(remoteHost.protocolVersion), older than local "
        + "protocol \(localHost.protocolVersion)"
    }

    let missingCapabilities = requiredRemoteCapabilities.subtracting(remoteHost.capabilities)
    guard missingCapabilities.isEmpty == false else {
      return "existing registry host is incompatible with this app"
    }

    let missingList = missingCapabilities
      .map(\.rawValue)
      .sorted()
      .joined(separator: ", ")
    return "existing registry host is missing required capabilities: \(missingList)"
  }

  private func sameHost(lhs: PingResult, rhs: PingResult) -> Bool {
    lhs.protocolVersion == rhs.protocolVersion
      && lhs.appVersion == rhs.appVersion
      && lhs.bundleIdentifier == rhs.bundleIdentifier
      && Set(lhs.capabilities) == Set(rhs.capabilities)
  }

  private func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
    let lhsParts = lhs.split(separator: ".").compactMap { Int($0) }
    let rhsParts = rhs.split(separator: ".").compactMap { Int($0) }
    let maxCount = max(lhsParts.count, rhsParts.count)

    for index in 0..<maxCount {
      let lhsValue = index < lhsParts.count ? lhsParts[index] : 0
      let rhsValue = index < rhsParts.count ? rhsParts[index] : 0
      if lhsValue < rhsValue {
        return .orderedAscending
      }
      if lhsValue > rhsValue {
        return .orderedDescending
      }
    }

    return .orderedSame
  }

  private func cleanupSocketFileIfPresent(at socketURL: URL) {
    guard FileManager.default.fileExists(atPath: socketURL.path) else {
      return
    }
    do {
      try FileManager.default.removeItem(at: socketURL)
    } catch {
      logger.error(
        """
        Failed to remove stale MCP socket at \
        \(socketURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)
        """
      )
    }
  }
}
