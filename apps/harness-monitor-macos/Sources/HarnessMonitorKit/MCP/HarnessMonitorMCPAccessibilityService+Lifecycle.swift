import Foundation
import HarnessMonitorRegistry

extension HarnessMonitorMCPAccessibilityService {
  static func makePingInfoProvider() -> @Sendable () -> PingResult {
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

  func waitForCompatibleRemoteHost(at path: String) async -> Bool {
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

  func waitForMatchingHost(at path: String, expectedHost: PingResult) async -> Bool {
    for _ in 0..<startupProbeCount {
      if let pingInfo = await pingSocket(at: path), sameHost(lhs: pingInfo, rhs: expectedHost) {
        return true
      }
      try? await Task.sleep(for: startupProbeDelay)
    }
    return false
  }

  func pingSocket(at path: String) async -> PingResult? {
    try? await socketClient.ping(at: path)
  }

  func attachToRemoteHost(at socket: URL) async {
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

  func requestReplacement(
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
        return .denied(
          "existing registry host acknowledged replacement but never yielded the socket"
        )
      }
      return .approved
    } catch {
      return .denied(
        "failed to notify the existing registry host about replacement: \(error.localizedDescription)"
      )
    }
  }

  func waitForSocketYield(at path: String, previousHost: PingResult) async -> Bool {
    for _ in 0..<startupProbeCount {
      guard let pingInfo = await pingSocket(at: path) else {
        return true
      }
      if sameHost(lhs: pingInfo, rhs: previousHost) == false {
        return true
      }
      try? await Task.sleep(for: startupProbeDelay)
    }
    return false
  }

  func handleReplacementNotice(
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

  func finalizeReplacementYield(
    _ notice: RegistryReplacementNotice,
    generation: UInt64
  ) async {
    guard
      acknowledgedReplacement == AcknowledgedReplacement(notice: notice, generation: generation)
    else {
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

  func finishReplacementYieldWait(
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

  func isCompatible(remoteHost: PingResult, localHost: PingResult) -> Bool {
    guard remoteHost.protocolVersion == localHost.protocolVersion else {
      return false
    }
    guard remoteHost.bundleIdentifier == localHost.bundleIdentifier else {
      return false
    }
    return Set(remoteHost.capabilities).isSuperset(of: requiredRemoteCapabilities)
  }

  func shouldReplace(remoteHost: PingResult, localHost: PingResult) -> Bool {
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

  func shouldYield(
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

  func incompatibilityReason(remoteHost: PingResult, localHost: PingResult) -> String {
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

    let missingList =
      missingCapabilities
      .map(\.rawValue)
      .sorted()
      .joined(separator: ", ")
    return "existing registry host is missing required capabilities: \(missingList)"
  }

  func sameHost(lhs: PingResult, rhs: PingResult) -> Bool {
    lhs.protocolVersion == rhs.protocolVersion
      && lhs.appVersion == rhs.appVersion
      && lhs.bundleIdentifier == rhs.bundleIdentifier
      && Set(lhs.capabilities) == Set(rhs.capabilities)
  }

  func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
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

  func cleanupSocketFileIfPresent(at socketURL: URL) {
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
