import Foundation

extension HarnessMonitorStore {
  func ensureManagedLaunchAgentReady(
    legacyCleanupAlreadyRequired: Bool = false
  ) async throws -> DaemonLaunchAgentRegistrationState {
    if legacyCleanupAlreadyRequired == false {
      try await requireLegacyManagedLaunchAgentCleanupOrThrow()
    }
    guard connection.legacyContainmentHealthy else {
      throw DaemonControlError.commandFailed(LegacyManagedLaunchAgentCleanup.failureMessage)
    }
    var registrationState = await daemonController.launchAgentRegistrationState()
    if registrationState == .notRegistered || registrationState == .notFound {
      registrationState = try await withControllerLegacyCleanupFailureTracking {
        try await daemonController.registerLaunchAgent()
      }
      try await requireLegacyManagedLaunchAgentCleanupOrThrow()
      registrationState = await daemonController.launchAgentRegistrationState()
    }
    return registrationState
  }

  /// Once per app launch, tear down and re-register the bundled SMAppService
  /// launch agent so launchd spawns the helper against a fresh BTM record
  /// and Launch Constraint Record. Without this, an Xcode rebuild between
  /// app launches leaves the prior `cs_mtime` cached in BTM and the next
  /// `xpcproxy` call fails with `EX_CONFIG` in a tight crash loop.
  ///
  /// No-op in `.external` ownership and on subsequent bootstrap passes
  /// within the same process (manifest watcher reconnects, app activation
  /// reconnects, etc.).
  func refreshManagedLaunchAgentOnFirstLaunchIfNeeded() async {
    guard daemonOwnership == .managed,
      hasRefreshedManagedLaunchAgentOnLaunch == false
    else {
      return
    }
    hasRefreshedManagedLaunchAgentOnLaunch = true
    do {
      let refreshed = try await withControllerLegacyCleanupFailureTracking {
        try await daemonController.refreshManagedLaunchAgentForLaunch()
      }
      if refreshed {
        try await requireLegacyManagedLaunchAgentCleanupOrThrow()
      }
    } catch {
      HarnessMonitorLogger.lifecycle.error(
        "On-launch managed launch agent refresh failed: \(error.localizedDescription, privacy: .public)"
      )
    }
  }
}
