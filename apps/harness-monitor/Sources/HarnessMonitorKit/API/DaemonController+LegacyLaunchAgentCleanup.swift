import Foundation

/// One-shot cleanup of old SMAppService plists. The current sandbox-safe
/// layout uses an app-group-child service name; earlier builds used
/// `io.harnessmonitor.daemon.managed` and pre-coexistence builds used
/// `io.harnessmonitor.daemon`. We unregister them before the current service
/// is inspected so an upgrade cannot leave two automation daemons running.
public enum LegacyManagedLaunchAgentCleanup {
  public static let completedNamesDefaultsKey =
    "HarnessMonitor.LegacyLaunchAgentCleanup.CompletedNames"
  static let strategyVersionDefaultsKey =
    "HarnessMonitor.LegacyLaunchAgentCleanup.StrategyVersion"
  static let strategyVersion = 2
  static let failureMessage =
    "Legacy daemon cleanup failed; daemon startup remains disabled to prevent duplicate automation"
  private static let lock = NSLock()
  private static let coordinator = LegacyManagedLaunchAgentCleanupCoordinator()
  nonisolated(unsafe) private static var didComplete = false

  private struct CleanupAttempt: Sendable {
    let isComplete: Bool
    let currentServiceWasUnregistered: Bool
  }

  /// Retries failed cleanup calls and caches success for the process lifetime.
  @discardableResult
  static func runOnce(
    defaults: UserDefaults = .standard,
    managerFactory: (String) -> any DaemonLaunchAgentManaging = {
      ServiceManagementDaemonLaunchAgentManager(plistName: $0)
    }
  ) -> Bool {
    serializedAttempt(defaults: defaults, managerFactory: managerFactory).isComplete
  }

  static func requireComplete(
    defaults: UserDefaults = .standard,
    managerFactory: @escaping @Sendable (String) -> any DaemonLaunchAgentManaging = {
      ServiceManagementDaemonLaunchAgentManager(plistName: $0)
    },
    afterCurrentServiceUnregister: @escaping @Sendable () async -> Void,
    quiesceOnFailure: @escaping @Sendable () async throws -> Void
  ) async throws {
    guard completedInThisProcess() == false else {
      return
    }
    let sendableDefaults = SendableUserDefaults(defaults)
    try await coordinator.run {
      while true {
        let attempt = await Task.detached(priority: .userInitiated) {
          serializedAttempt(defaults: sendableDefaults.value, managerFactory: managerFactory)
        }.value
        if attempt.isComplete {
          return
        }
        if attempt.currentServiceWasUnregistered {
          await afterCurrentServiceUnregister()
          continue
        }
        try await quiesceOnFailure()
        throw DaemonControlError.commandFailed(failureMessage)
      }
    }
  }

  static func completedInThisProcess() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return didComplete
  }

  private static func serializedAttempt(
    defaults: UserDefaults,
    managerFactory: (String) -> any DaemonLaunchAgentManaging
  ) -> CleanupAttempt {
    lock.lock()
    defer { lock.unlock() }
    if didComplete {
      return CleanupAttempt(isComplete: true, currentServiceWasUnregistered: false)
    }
    let result = performCleanup(defaults: defaults, managerFactory: managerFactory)
    didComplete = result.isComplete
    return result
  }

  private static func performCleanup(
    defaults: UserDefaults,
    managerFactory: (String) -> any DaemonLaunchAgentManaging
  ) -> CleanupAttempt {
    let currentName = HarnessMonitorPaths.launchAgentPlistName
    let usesCurrentStrategy =
      defaults.integer(forKey: strategyVersionDefaultsKey) == strategyVersion
    var completedNames =
      usesCurrentStrategy
      ? Set(defaults.stringArray(forKey: completedNamesDefaultsKey) ?? [])
      : []
    var failedNames: [String] = []
    for legacyName in HarnessMonitorPaths.legacyLaunchAgentPlistNames
    where legacyName != currentName {
      let legacyService = managerFactory(legacyName)
      let state = legacyService.registrationState()
      if completedNames.contains(legacyName), state == .notRegistered || state == .notFound {
        continue
      }
      completedNames.remove(legacyName)
      HarnessMonitorLogger.lifecycle.info(
        """
        Legacy SMAppService cleanup: legacy_plist=\(legacyName, privacy: .public) \
        current_plist=\(currentName, privacy: .public) \
        status=\(String(describing: state), privacy: .public)
        """
      )
      let completed =
        state == .notRegistered || state == .notFound
        || attemptUnregister(legacyService, name: legacyName)
      if completed {
        completedNames.insert(legacyName)
      } else {
        failedNames.append(legacyName)
      }
    }

    defaults.set(completedNames.sorted(), forKey: completedNamesDefaultsKey)
    defaults.set(strategyVersion, forKey: strategyVersionDefaultsKey)
    guard failedNames.isEmpty else {
      return CleanupAttempt(
        isComplete: false,
        currentServiceWasUnregistered: disableCurrentService(
          managerFactory(currentName),
          name: currentName
        )
      )
    }
    return CleanupAttempt(isComplete: true, currentServiceWasUnregistered: false)
  }

  /// Test-only escape hatch: clears the once-guard so a unit test can verify
  /// the runOnce path more than once in the same process.
  static func resetForTests() {
    lock.lock()
    didComplete = false
    lock.unlock()
  }

  private static func disableCurrentService(
    _ service: any DaemonLaunchAgentManaging,
    name: String
  ) -> Bool {
    switch service.registrationState() {
    case .notRegistered, .notFound:
      return false
    case .enabled, .requiresApproval:
      break
    }
    do {
      try service.unregister()
      HarnessMonitorLogger.lifecycle.notice(
        "Disabled current SMAppService after legacy cleanup failed: \(name, privacy: .public)"
      )
      return true
    } catch {
      HarnessMonitorLogger.lifecycle.fault(
        """
        Could not disable current SMAppService \(name, privacy: .public): \
        \(error.localizedDescription, privacy: .public)
        """
      )
      return false
    }
  }

  private static func attemptUnregister(
    _ service: any DaemonLaunchAgentManaging,
    name: String
  ) -> Bool {
    do {
      try service.unregister()
      HarnessMonitorLogger.lifecycle.info(
        "Auto-unregistered legacy SMAppService plist \(name, privacy: .public)"
      )
      return true
    } catch {
      HarnessMonitorLogger.lifecycle.notice(
        """
        Could not unregister legacy SMAppService plist \(name, privacy: .public): \
        \(error.localizedDescription, privacy: .public)
        """
      )
      return false
    }
  }
}

/// Foundation documents UserDefaults as thread-safe. This wrapper makes that
/// contract explicit while cleanup executes outside the main actor.
private struct SendableUserDefaults: @unchecked Sendable {
  let value: UserDefaults

  init(_ value: UserDefaults) {
    self.value = value
  }
}

private actor LegacyManagedLaunchAgentCleanupCoordinator {
  private var inFlight: Task<Void, any Error>?

  func run(
    _ operation: @escaping @Sendable () async throws -> Void
  ) async throws {
    if let inFlight {
      try await inFlight.value
      return
    }

    let task = Task { try await operation() }
    inFlight = task
    defer { inFlight = nil }
    try await task.value
  }
}

private enum ManagedDaemonQuiescenceAction {
  case finish
  case wait
  case requestStop
}

extension DaemonController {
  public func requireLegacyManagedLaunchAgentCleanup() async throws {
    guard LegacyManagedLaunchAgentCleanup.completedInThisProcess() == false else {
      return
    }
    let outcome = try await withManagedLaunchAgentLock(totalTimeout: .seconds(2)) {
      try await LegacyManagedLaunchAgentCleanup.requireComplete(
        afterCurrentServiceUnregister: {
          clearManagedLaunchAgentBundleStamp()
          clearManagedLaunchAgentOwner()
          if managedLaunchAgentBTMSettleDelay > .zero {
            try? await managedLaunchAgentBTMSettleSleep(managedLaunchAgentBTMSettleDelay)
          }
        },
        quiesceOnFailure: {
          try await quiesceManagedDaemonsAfterLegacyCleanupFailure()
        }
      )
    }
    guard case .acquired = outcome else {
      throw DaemonControlError.commandFailed(
        "Legacy daemon cleanup is busy in another Harness Monitor process"
      )
    }
  }

  func quiesceManagedDaemonsAfterLegacyCleanupFailure() async throws {
    let candidates = HarnessMonitorPaths.managedDaemonRootCandidates(using: environment)
    var failures: [String] = []
    var stoppedCount = 0
    for candidate in candidates {
      do {
        if try await quiesceManagedDaemon(at: candidate) {
          stoppedCount += 1
        }
      } catch {
        failures.append("\(candidate.rootURL.path): \(error.localizedDescription)")
      }
    }
    guard failures.isEmpty else {
      throw DaemonControlError.commandFailed(
        "Managed daemon quiescence failed: \(failures.joined(separator: "; "))"
      )
    }
    if stoppedCount > 0 {
      HarnessMonitorLogger.lifecycle.fault(
        "Stopped managed automation after legacy daemon cleanup failed"
      )
    }
  }

  private func quiesceManagedDaemon(
    at candidate: ManagedDaemonRootCandidate
  ) async throws -> Bool {
    let deadline = ContinuousClock.now + managedStaleManifestGracePeriod
    var stopRequestedPID: Int32?
    var stoppedAny = false
    while true {
      let lockIsHeld = daemonSingletonLockIsHeld(at: candidate.singletonLockURL)
      switch HarnessMonitorPaths.probeManagedDaemonManifest(at: candidate.manifestURL) {
      case .absent, .invalid:
        guard lockIsHeld else {
          return stoppedAny
        }
      case .external:
        return stoppedAny
      case .managed(let pid):
        switch managedDaemonQuiescenceAction(
          pid: pid,
          lockIsHeld: lockIsHeld,
          stopRequestedPID: stopRequestedPID
        ) {
        case .finish:
          return stoppedAny
        case .wait:
          break
        case .requestStop:
          let manifest = try loadManifest(
            at: candidate.manifestURL,
            emitTrace: false,
            activate: false,
            recoverEndpoint: false
          )
          guard manifest.pid == Int(pid) else {
            continue
          }
          try await requestManagedDaemonQuiescence(
            manifest,
            trustedDaemonRoot: candidate.rootURL
          )
          stopRequestedPID = pid
          stoppedAny = true
        }
      }
      guard ContinuousClock.now < deadline else {
        throw DaemonControlError.commandFailed(
          "managed daemon did not release its singleton lock before timeout"
        )
      }
      try await Task.sleep(for: .milliseconds(50))
    }
  }

  private func managedDaemonQuiescenceAction(
    pid: Int32,
    lockIsHeld: Bool,
    stopRequestedPID: Int32?
  ) -> ManagedDaemonQuiescenceAction {
    if stopRequestedPID == pid {
      return lockIsHeld ? .wait : .finish
    }
    if processLiveness(pid) == .dead {
      return lockIsHeld ? .wait : .finish
    }
    return .requestStop
  }

  private func requestManagedDaemonQuiescence(
    _ manifest: DaemonManifest,
    trustedDaemonRoot: URL
  ) async throws {
    let endpoint = try endpointURL(from: manifest.endpoint)
    guard Self.isTrustedManagedEndpoint(endpoint) else {
      throw DaemonControlError.invalidManifest(
        "managed daemon endpoints must use loopback http(s): \(manifest.endpoint)"
      )
    }
    let connection = try daemonConnection(
      from: manifest,
      trustedDaemonRoot: trustedDaemonRoot,
      emitTrace: false
    )
    let client = sessionFactory(connection)
    do {
      _ = try? await client.setPolicyCanvasSpawnKillSwitch(
        request: PolicyCanvasSetSpawnKillSwitchRequest(enabled: true)
      )
      _ = try await client.stopDaemon()
      await client.shutdown()
    } catch {
      await client.shutdown()
      throw error
    }
  }
}
