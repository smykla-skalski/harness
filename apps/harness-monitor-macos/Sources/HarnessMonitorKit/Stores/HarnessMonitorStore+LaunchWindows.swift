import Foundation

extension HarnessMonitorStore {
  public static let launchWindowBridgeFallbackKey =
    "harness.monitor.launch-window.bridge-fallback-done"

  public func recentSessionIDsForLaunchWindows(limit: Int) async -> [String] {
    await recentSessionIDsForLaunchWindows(
      limit: limit,
      userDefaults: .standard
    )
  }

  func recentSessionIDsForLaunchWindows(
    limit: Int,
    userDefaults: UserDefaults
  ) async -> [String] {
    let normalizedLimit = max(limit, 0)
    guard normalizedLimit > 0 else { return [] }

    let openAtQuit = await sessionWindowIDsOpenAtQuit(limit: normalizedLimit)
    if !openAtQuit.isEmpty {
      return openAtQuit
    }
    let hasPriorWindowState = await rawSessionWindowsOpenAtQuitExist()
    if hasPriorWindowState || hasCompletedLaunchWindowBridgeFallback(userDefaults: userDefaults) {
      return []
    }
    markLaunchWindowBridgeFallbackComplete(userDefaults: userDefaults)
    var bridgedIDs = await recentlyViewedSessionIDs(limit: normalizedLimit)
    appendFallbackRecentSessionIDs(to: &bridgedIDs, limit: normalizedLimit)
    return Array(bridgedIDs.prefix(normalizedLimit))
  }

  private func rawSessionWindowsOpenAtQuitExist() async -> Bool {
    guard let cacheService else { return false }
    return await !cacheService.sessionWindowIDsOpenAtQuit(limit: 1).isEmpty
  }

  public func registerOpenSessionWindow(sessionID: String) {
    openSessionWindowIDs.insert(sessionID)
  }

  public func unregisterOpenSessionWindow(sessionID: String) {
    openSessionWindowIDs.remove(sessionID)
  }

  public var openSessionWindowIDsSnapshot: Set<String> {
    openSessionWindowIDs
  }

  public func beginSessionWindowTerminationSnapshot() {
    pendingSessionWindowTerminationSnapshot = openSessionWindowIDs
  }

  public func flushSessionWindowsOpenAtQuit() async {
    await flushSessionWindowsOpenAtQuit(userDefaults: .standard)
  }

  func flushSessionWindowsOpenAtQuit(userDefaults: UserDefaults) async {
    let snapshot = pendingSessionWindowTerminationSnapshot ?? openSessionWindowIDs
    pendingSessionWindowTerminationSnapshot = nil
    guard let cacheService, persistenceError == nil else { return }
    _ = await cacheService.replaceSessionWindowsOpenAtQuit(sessionIDs: snapshot)
    markLaunchWindowBridgeFallbackComplete(userDefaults: userDefaults)
  }

  private func sessionWindowIDsOpenAtQuit(limit: Int) async -> [String] {
    guard let cacheService else { return [] }
    let knownSessionIDs = Set(sessionIndex.catalog.sessions.map(\.sessionId))
    return await cacheService.sessionWindowIDsOpenAtQuit(limit: limit)
      .filter { knownSessionIDs.contains($0) }
  }

  private func recentlyViewedSessionIDs(limit: Int) async -> [String] {
    guard let cacheService else { return [] }
    let knownSessionIDs = Set(sessionIndex.catalog.sessions.map(\.sessionId))
    return await cacheService.recentlyViewedSessionIDs(limit: limit)
      .filter { knownSessionIDs.contains($0) }
  }

  private func appendFallbackRecentSessionIDs(to sessionIDs: inout [String], limit: Int) {
    var seen = Set(sessionIDs)
    for summary in sessionIndex.catalog.recentSessions where sessionIDs.count < limit {
      guard seen.insert(summary.sessionId).inserted else {
        continue
      }
      sessionIDs.append(summary.sessionId)
    }
  }

  private func hasCompletedLaunchWindowBridgeFallback(
    userDefaults: UserDefaults
  ) -> Bool {
    userDefaults.bool(forKey: Self.launchWindowBridgeFallbackKey)
  }

  private func markLaunchWindowBridgeFallbackComplete(
    userDefaults: UserDefaults
  ) {
    userDefaults.set(true, forKey: Self.launchWindowBridgeFallbackKey)
  }
}
