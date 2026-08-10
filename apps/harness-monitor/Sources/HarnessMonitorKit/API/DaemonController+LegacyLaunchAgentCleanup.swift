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

  private struct CleanupAttempt: Sendable {
    let isComplete: Bool
    let currentServiceWasUnregistered: Bool
  }

  /// Rechecks persisted successes because an older app can register a legacy
  /// service again while this process is still running.
  @discardableResult
  static func runOnce(
    defaults: UserDefaults = .standard,
    currentName: String = HarnessMonitorPaths.launchAgentPlistName,
    legacyNames: [String] = HarnessMonitorPaths.legacyLaunchAgentPlistNames,
    managerFactory: (String) -> any DaemonLaunchAgentManaging = {
      ServiceManagementDaemonLaunchAgentManager(plistName: $0)
    }
  ) -> Bool {
    serializedAttempt(
      defaults: defaults,
      currentName: currentName,
      legacyNames: legacyNames,
      managerFactory: managerFactory
    ).isComplete
  }

  static func requireComplete(
    defaults: UserDefaults = .standard,
    currentName: String = HarnessMonitorPaths.launchAgentPlistName,
    legacyNames: [String] = HarnessMonitorPaths.legacyLaunchAgentPlistNames,
    managerFactory: @escaping @Sendable (String) -> any DaemonLaunchAgentManaging = {
      ServiceManagementDaemonLaunchAgentManager(plistName: $0)
    },
    legacyMonitorProcessIsRunning: @escaping @Sendable () async -> Bool = { false },
    afterCurrentServiceUnregister: @escaping @Sendable () async -> Void,
    quiesceOnFailure: @escaping @Sendable () async throws -> Void
  ) async throws {
    let sendableDefaults = SendableUserDefaults(defaults)
    let legacyMonitorIsRunning = await legacyMonitorProcessIsRunning()
    var attempt = await detachedAttempt(
      defaults: sendableDefaults,
      currentName: currentName,
      legacyNames: legacyNames,
      legacyMonitorIsRunning: legacyMonitorIsRunning,
      managerFactory: managerFactory
    )
    try Task.checkCancellation()
    if attempt.isComplete {
      return
    }
    if attempt.currentServiceWasUnregistered {
      await afterCurrentServiceUnregister()
      try Task.checkCancellation()
      attempt = await detachedAttempt(
        defaults: sendableDefaults,
        currentName: currentName,
        legacyNames: legacyNames,
        legacyMonitorIsRunning: await legacyMonitorProcessIsRunning(),
        managerFactory: managerFactory
      )
      try Task.checkCancellation()
      if attempt.isComplete {
        return
      }
      if attempt.currentServiceWasUnregistered {
        await afterCurrentServiceUnregister()
      }
    }
    try Task.checkCancellation()
    try await quiesceOnFailure()
    throw DaemonControlError.commandFailed(failureMessage)
  }

  private static func detachedAttempt(
    defaults: SendableUserDefaults,
    currentName: String,
    legacyNames: [String],
    legacyMonitorIsRunning: Bool,
    managerFactory: @escaping @Sendable (String) -> any DaemonLaunchAgentManaging
  ) async -> CleanupAttempt {
    await Task.detached(priority: .userInitiated) {
      serializedAttempt(
        defaults: defaults.value,
        currentName: currentName,
        legacyNames: legacyNames,
        legacyMonitorIsRunning: legacyMonitorIsRunning,
        managerFactory: managerFactory
      )
    }.value
  }

  private static func serializedAttempt(
    defaults: UserDefaults,
    currentName: String,
    legacyNames: [String],
    legacyMonitorIsRunning: Bool = false,
    managerFactory: (String) -> any DaemonLaunchAgentManaging
  ) -> CleanupAttempt {
    lock.lock()
    defer { lock.unlock() }
    return performCleanup(
      defaults: defaults,
      currentName: currentName,
      legacyNames: legacyNames,
      legacyMonitorIsRunning: legacyMonitorIsRunning,
      managerFactory: managerFactory
    )
  }

  private static func performCleanup(
    defaults: UserDefaults,
    currentName: String,
    legacyNames: [String],
    legacyMonitorIsRunning: Bool,
    managerFactory: (String) -> any DaemonLaunchAgentManaging
  ) -> CleanupAttempt {
    let usesCurrentStrategy =
      defaults.integer(forKey: strategyVersionDefaultsKey) == strategyVersion
    var completedNames =
      usesCurrentStrategy
      ? Set(defaults.stringArray(forKey: completedNamesDefaultsKey) ?? [])
      : []
    var failedNames: [String] = []
    for legacyName in legacyNames
    where legacyName != currentName {
      let legacyService = managerFactory(legacyName)
      let state = legacyService.registrationState()
      if completedNames.contains(legacyName), state == .notRegistered {
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
        state == .notRegistered
        || attemptUnregister(legacyService, name: legacyName)
      if completed {
        completedNames.insert(legacyName)
      } else {
        failedNames.append(legacyName)
      }
    }

    persistCleanupStateIfChanged(completedNames, defaults: defaults)
    guard failedNames.isEmpty, !legacyMonitorIsRunning else {
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

  private static func persistCleanupStateIfChanged(
    _ completedNames: Set<String>,
    defaults: UserDefaults
  ) {
    let sortedNames = completedNames.sorted()
    if defaults.stringArray(forKey: completedNamesDefaultsKey) != sortedNames {
      defaults.set(sortedNames, forKey: completedNamesDefaultsKey)
    }
    if defaults.integer(forKey: strategyVersionDefaultsKey) != strategyVersion {
      defaults.set(strategyVersion, forKey: strategyVersionDefaultsKey)
    }
  }

  private static func disableCurrentService(
    _ service: any DaemonLaunchAgentManaging,
    name: String
  ) -> Bool {
    switch service.registrationState() {
    case .notRegistered:
      return false
    case .enabled, .requiresApproval, .notFound:
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
struct SendableUserDefaults: @unchecked Sendable {
  let value: UserDefaults

  init(_ value: UserDefaults) {
    self.value = value
  }
}

extension DaemonController {
  func registerCurrentLaunchAgentAndRequireLegacyCleanup()
    async throws -> DaemonLaunchAgentRegistrationState
  {
    try launchAgentManager.register()
    let state = launchAgentManager.registrationState()
    do {
      try await requireLegacyManagedLaunchAgentCleanup()
    } catch is CancellationError {
      guard await disableCurrentLaunchAgentAfterCleanupFailure() else {
        throw DaemonControlError.legacyManagedLaunchAgentCleanupFailed
      }
      throw CancellationError()
    } catch {
      _ = await disableCurrentLaunchAgentAfterCleanupFailure()
      throw DaemonControlError.legacyManagedLaunchAgentCleanupFailed
    }
    return state
  }

  private func disableCurrentLaunchAgentAfterCleanupFailure() async -> Bool {
    guard launchAgentManager.registrationState() != .notRegistered else {
      return true
    }
    do {
      try launchAgentManager.unregister()
    } catch {
      return false
    }
    clearManagedLaunchAgentBundleStamp()
    clearManagedLaunchAgentOwner()
    await awaitManagedLaunchAgentBTMSettleAfterCancelledUnregister()
    return true
  }

  public func requireLegacyManagedLaunchAgentCleanup() async throws {
    let outcome = try await withLegacyManagedLaunchAgentLock(totalTimeout: .seconds(2)) {
      try await LegacyManagedLaunchAgentCleanup.requireComplete(
        defaults: legacyLaunchAgentCleanupDefaults.value,
        currentName: HarnessMonitorPaths.launchAgentPlistName(using: environment),
        legacyNames: HarnessMonitorPaths.legacyLaunchAgentPlistNames,
        managerFactory: legacyLaunchAgentManagerFactory,
        legacyMonitorProcessIsRunning: legacyMonitorProcessIsRunning,
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
}

struct InactiveDaemonLaunchAgentManager: DaemonLaunchAgentManaging {
  func registrationState() -> DaemonLaunchAgentRegistrationState {
    .notRegistered
  }

  func register() throws {}

  func unregister() throws {}
}
