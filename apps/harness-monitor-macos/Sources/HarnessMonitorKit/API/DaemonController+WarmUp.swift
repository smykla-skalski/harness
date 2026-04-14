import Foundation

extension DaemonController {
  public func awaitManifestWarmUp(
    timeout: Duration
  ) async throws -> any HarnessMonitorClientProtocol {
    try refreshManagedLaunchAgentIfBundledHelperChanged()
    let timeoutDesc = String(describing: timeout)
    HarnessMonitorLogger.lifecycle.trace(
      "Waiting up to \(timeoutDesc, privacy: .public) for daemon manifest warm-up"
    )
    let deadline = ContinuousClock.now + timeout
    var state = WarmUpLoopState()
    while ContinuousClock.now < deadline {
      let shouldBreak = try await warmUpIteration(state: &state)
      if let client = shouldBreak.liveClient {
        return client
      }
      if shouldBreak.stop { break }
      try await Task.sleep(for: .milliseconds(250))
    }
    if let immediateError = state.immediateError {
      throw immediateError
    }
    if state.skipFinalBootstrapProbe == false, let client = try? await bootstrapClient() {
      return client
    }
    if ownership == .external {
      let manifestPath = HarnessMonitorPaths.manifestURL(using: environment).path
      if state.sawUnreachableManifest {
        // Manifest existed throughout the warm-up but nothing bound to its
        // endpoint. Classic crash-without-cleanup: SIGKILL'd dev daemon.
        throw DaemonControlError.externalDaemonManifestStale(manifestPath: manifestPath)
      }
      // No manifest ever appeared; the dev daemon was never started.
      throw DaemonControlError.externalDaemonOffline(manifestPath: manifestPath)
    }
    throw state.lastError ?? DaemonControlError.daemonDidNotStart
  }

  struct WarmUpLoopState {
    var lastError: (any Error)?
    var sawUnreachableManifest = false
    var immediateError: (any Error)?
    var skipFinalBootstrapProbe = false
    var managedStaleManifestTracker = ManagedStaleManifestTracker()
  }

  struct WarmUpIterationOutcome {
    var liveClient: (any HarnessMonitorClientProtocol)?
    var stop: Bool

    static let continueLoop = Self(liveClient: nil, stop: false)
    static let stopLoop = Self(liveClient: nil, stop: true)
  }

  func warmUpIteration(
    state: inout WarmUpLoopState
  ) async throws -> WarmUpIterationOutcome {
    do {
      let manifest = try loadManifest()
      if let mismatch = managedDaemonVersionMismatch(for: manifest) {
        state.lastError = mismatch
        state.immediateError = mismatch
        return .stopLoop
      }
      let connection = try daemonConnection(from: manifest)
      let endpoint = connection.endpoint.absoluteString
      let manifestPid = manifest.pid
      HarnessMonitorLogger.lifecycle.trace(
        "\(Self.warmUpObservedManifestMessage(pid: manifestPid, endpoint: endpoint), privacy: .public)"
      )
      if await endpointProbe(connection.endpoint) {
        HarnessMonitorLogger.lifecycle.trace(
          "Warm-up confirmed live daemon endpoint \(endpoint, privacy: .public)"
        )
        let client = try await bootstrap(connection: connection)
        return WarmUpIterationOutcome(liveClient: client, stop: true)
      }
      return handleStaleManifest(manifest: manifest, endpoint: endpoint, state: &state)
    } catch let error as DaemonControlError {
      state.managedStaleManifestTracker.reset()
      if case .invalidManifest = error, ownership == .external {
        state.immediateError = error
        return .stopLoop
      }
      state.lastError = error
      HarnessMonitorLogger.lifecycle.trace(
        "Warm-up retry after \(error.localizedDescription, privacy: .public)"
      )
    } catch {
      state.managedStaleManifestTracker.reset()
      state.lastError = error
      HarnessMonitorLogger.lifecycle.trace(
        "Warm-up retry after \(error.localizedDescription, privacy: .public)"
      )
    }
    return .continueLoop
  }

  func handleStaleManifest(
    manifest: DaemonManifest,
    endpoint: String,
    state: inout WarmUpLoopState
  ) -> WarmUpIterationOutcome {
    let manifestPath = HarnessMonitorPaths.manifestURL(using: environment).path
    HarnessMonitorLogger.lifecycle.error(
      "\(Self.warmUpStaleManifestMessage(path: manifestPath, endpoint: endpoint), privacy: .public)"
    )
    state.sawUnreachableManifest = true
    if ownership == .external {
      state.immediateError = DaemonControlError.externalDaemonManifestStale(
        manifestPath: manifestPath
      )
      return .stopLoop
    }
    return handleManagedStaleManifest(manifest: manifest, path: manifestPath, state: &state)
  }

  func handleManagedStaleManifest(
    manifest: DaemonManifest,
    path: String,
    state: inout WarmUpLoopState
  ) -> WarmUpIterationOutcome {
    state.lastError = DaemonControlError.daemonDidNotStart
    if Self.processIsAlive(pid: manifest.pid) == false {
      state.skipFinalBootstrapProbe = true
      state.immediateError = DaemonControlError.daemonDidNotStart
      let pid = manifest.pid
      HarnessMonitorLogger.lifecycle.error(
        "\(Self.warmUpDeadManagedManifestMessage(pid: pid, path: path), privacy: .public)"
      )
      return .stopLoop
    }
    let staleSignature = Self.managedStaleManifestSignature(for: manifest)
    let gracePeriod = String(describing: managedStaleManifestGracePeriod)
    if state.managedStaleManifestTracker.expired(
      signature: staleSignature,
      now: ContinuousClock.now,
      gracePeriod: managedStaleManifestGracePeriod
    ) {
      let timeoutMessage = Self.warmUpManagedStaleManifestTimeoutMessage(
        path: path,
        gracePeriod: gracePeriod
      )
      HarnessMonitorLogger.lifecycle.error(
        "\(timeoutMessage, privacy: .public)"
      )
      return .stopLoop
    }
    HarnessMonitorLogger.lifecycle.trace(
      "Warm-up waiting for managed daemon to rewrite stale manifest at \(path, privacy: .public)"
    )
    return .continueLoop
  }

  static func managedStaleManifestSignature(for manifest: DaemonManifest) -> String {
    "\(manifest.pid)|\(manifest.endpoint)|\(manifest.startedAt)"
  }

  static func warmUpObservedManifestMessage(pid: Int, endpoint: String) -> String {
    "Warm-up observed manifest pid=\(pid) endpoint=\(endpoint)"
  }

  static func warmUpStaleManifestMessage(path: String, endpoint: String) -> String {
    "Warm-up found stale daemon manifest at \(path) endpoint=\(endpoint)"
  }

  static func warmUpDeadManagedManifestMessage(pid: Int, path: String) -> String {
    "Warm-up detected dead managed daemon pid \(pid) stale-manifest=\(path)"
  }

  static func warmUpManagedStaleManifestTimeoutMessage(
    path: String,
    gracePeriod: String
  ) -> String {
    "Warm-up aborting managed stale manifest wait at \(path) grace-period=\(gracePeriod)"
  }

  static func processIsAlive(pid: Int) -> Bool? {
    guard pid > 0 else {
      return nil
    }

    if kill(pid_t(pid), 0) == 0 {
      return true
    }

    switch errno {
    case ESRCH:
      return false
    case EPERM:
      return true
    default:
      return nil
    }
  }

  func refreshManagedLaunchAgentIfBundledHelperChanged() throws {
    guard ownership == .managed else {
      return
    }
    guard launchAgentManager.registrationState() == .enabled else {
      return
    }
    guard let currentStamp = try managedLaunchAgentCurrentBundleStamp() else {
      return
    }

    let stampURL = HarnessMonitorPaths.managedLaunchAgentBundleStampURL(using: environment)
    guard let persistedStamp = loadManagedLaunchAgentBundleStamp(from: stampURL) else {
      try persistManagedLaunchAgentBundleStamp(currentStamp, to: stampURL)
      return
    }
    guard persistedStamp != currentStamp else {
      return
    }

    HarnessMonitorLogger.lifecycle.notice(
      "Bundled managed daemon helper changed; refreshing launch agent before warm-up"
    )
    try launchAgentManager.unregister()
    clearManagedLaunchAgentBundleStamp(at: stampURL)
    try launchAgentManager.register()
    if launchAgentManager.registrationState() == .enabled {
      try persistManagedLaunchAgentBundleStamp(currentStamp, to: stampURL)
    }
  }

  func persistCurrentManagedLaunchAgentBundleStamp() throws {
    guard let currentStamp = try managedLaunchAgentCurrentBundleStamp() else {
      return
    }
    try persistManagedLaunchAgentBundleStamp(
      currentStamp,
      to: HarnessMonitorPaths.managedLaunchAgentBundleStampURL(using: environment)
    )
  }

  func loadManagedLaunchAgentBundleStamp(from url: URL) -> ManagedLaunchAgentBundleStamp? {
    guard let data = FileManager.default.contents(atPath: url.path) else {
      return nil
    }
    return try? JSONDecoder().decode(ManagedLaunchAgentBundleStamp.self, from: data)
  }

  func persistManagedLaunchAgentBundleStamp(
    _ stamp: ManagedLaunchAgentBundleStamp,
    to url: URL
  ) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(stamp)
    try data.write(to: url, options: .atomic)
  }

  func clearManagedLaunchAgentBundleStamp() {
    clearManagedLaunchAgentBundleStamp(
      at: HarnessMonitorPaths.managedLaunchAgentBundleStampURL(using: environment)
    )
  }

  func clearManagedLaunchAgentBundleStamp(at url: URL) {
    try? FileManager.default.removeItem(at: url)
  }
}
