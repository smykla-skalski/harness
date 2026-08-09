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
    let pendingNames = HarnessMonitorPaths.legacyLaunchAgentPlistNames
      .filter {
        $0 != currentName
          && !completedNames.contains($0)
      }
    guard pendingNames.isEmpty == false else {
      defaults.set(strategyVersion, forKey: strategyVersionDefaultsKey)
      return CleanupAttempt(isComplete: true, currentServiceWasUnregistered: false)
    }

    var failedNames: [String] = []
    for legacyName in pendingNames {
      let legacyService = managerFactory(legacyName)
      let state = legacyService.registrationState()
      HarnessMonitorLogger.lifecycle.info(
        """
        Legacy SMAppService cleanup: legacy_plist=\(legacyName, privacy: .public) \
        current_plist=\(currentName, privacy: .public) \
        status=\(String(describing: state), privacy: .public)
        """
      )
      let completed =
        state == .notRegistered
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
    let manifestURLs = HarnessMonitorPaths.liveManagedDaemonManifestURLs(using: environment)
    for manifestURL in manifestURLs {
      let manifest = try loadManifest(at: manifestURL, emitTrace: false)
      let endpoint = try endpointURL(from: manifest.endpoint)
      guard Self.isTrustedManagedEndpoint(endpoint) else {
        throw DaemonControlError.invalidManifest(
          "managed daemon endpoints must use loopback http(s): \(manifest.endpoint)"
        )
      }
      let connection = try daemonConnection(from: manifest, emitTrace: false)
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
    if manifestURLs.isEmpty == false {
      HarnessMonitorLogger.lifecycle.fault(
        "Stopped managed automation after legacy daemon cleanup failed"
      )
    }
  }
}
