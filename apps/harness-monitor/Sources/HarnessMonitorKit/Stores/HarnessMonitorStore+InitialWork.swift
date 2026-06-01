import Foundation
import Observation
import SwiftData

extension HarnessMonitorStore {
  /// Applies environment-derived configuration and kicks off the initial UI and
  /// background work that follows stored-property setup in `init`.
  func applyEnvironmentConfigurationAndStartInitialWork() {
    if let raw = ProcessInfo.processInfo.environment["HARNESS_BOOTSTRAP_TIMEOUT_SECONDS"],
      let seconds = Double(raw),
      seconds > 0
    {
      self.bootstrapWarmUpTimeout = .seconds(seconds)
    }
    let seeded = Self.parseForcedBridgeIssues(
      from: ProcessInfo.processInfo.environment
    )
    self.hostBridgeCapabilityIssues = seeded
    self.forcedHostBridgeCapabilities = Set(seeded.keys)
    configureToastHistoryEvents()
    bindUISlices()
    syncAllUI()
    scheduleBookmarkedSessionRefresh()
    scheduleApplicationAuditCacheRefresh()
    scheduleNotificationHistoryRefresh()
  }
}
