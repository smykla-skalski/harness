import Foundation

extension HarnessMonitorStore {
  public static let launchWindowBridgeFallbackKey =
    "harness.monitor.launch-window.bridge-fallback-done"

  public struct LaunchWindowRestorePlan: Equatable, Sendable {
    public let sessionIDs: [String]
    public let usedBridgeFallback: Bool

    public init(
      sessionIDs: [String] = [],
      usedBridgeFallback: Bool = false
    ) {
      self.sessionIDs = sessionIDs
      self.usedBridgeFallback = usedBridgeFallback
    }
  }

  public func launchWindowRestorePlan(
    userDefaults: UserDefaults = .standard
  ) async -> LaunchWindowRestorePlan {
    let openAtQuit = await sessionWindowIDsOpenAtQuit()
    if !openAtQuit.isEmpty {
      return LaunchWindowRestorePlan(sessionIDs: openAtQuit)
    }
    let hasPriorWindowState = await rawSessionWindowsOpenAtQuitExist()
    if hasPriorWindowState || hasCompletedLaunchWindowBridgeFallback(userDefaults: userDefaults) {
      return LaunchWindowRestorePlan()
    }
    var bridgedIDs = await recentlyViewedSessionIDs()
    appendFallbackRecentSessionIDs(to: &bridgedIDs)
    return LaunchWindowRestorePlan(
      sessionIDs: bridgedIDs,
      usedBridgeFallback: true
    )
  }

  public func completeLaunchWindowBridgeFallback(
    userDefaults: UserDefaults = .standard
  ) {
    markLaunchWindowBridgeFallbackComplete(userDefaults: userDefaults)
  }

  private func rawSessionWindowsOpenAtQuitExist() async -> Bool {
    guard let cacheService else { return false }
    return await !cacheService.sessionWindowIDsOpenAtQuit(limit: 1).isEmpty
  }

  public func registerOpenSessionWindow(
    windowID: ObjectIdentifier,
    sessionID: String
  ) {
    openSessionWindowsByID[windowID] = sessionID
  }

  public func unregisterOpenSessionWindow(windowID: ObjectIdentifier) {
    openSessionWindowsByID.removeValue(forKey: windowID)
  }

  public var openSessionWindowIDsSnapshot: Set<String> {
    Set(openSessionWindowsByID.values)
  }

  public func beginSessionWindowTerminationSnapshot() {
    pendingSessionWindowTerminationSnapshot = openSessionWindowIDsSnapshot
  }

  public func flushSessionWindowsOpenAtQuit() async {
    await flushSessionWindowsOpenAtQuit(userDefaults: .standard)
  }

  func flushSessionWindowsOpenAtQuit(userDefaults: UserDefaults) async {
    let snapshot = pendingSessionWindowTerminationSnapshot ?? openSessionWindowIDsSnapshot
    pendingSessionWindowTerminationSnapshot = nil
    guard let cacheService, persistenceError == nil else { return }
    _ = await cacheService.replaceSessionWindowsOpenAtQuit(sessionIDs: snapshot)
    markLaunchWindowBridgeFallbackComplete(userDefaults: userDefaults)
  }

  private func sessionWindowIDsOpenAtQuit() async -> [String] {
    guard let cacheService else { return [] }
    let knownSessionIDs = Set(sessionIndex.catalog.sessions.map(\.sessionId))
    return await cacheService.sessionWindowIDsOpenAtQuit()
      .filter { knownSessionIDs.contains($0) }
  }

  private func recentlyViewedSessionIDs() async -> [String] {
    guard let cacheService else { return [] }
    let knownSessionIDs = Set(sessionIndex.catalog.sessions.map(\.sessionId))
    return await cacheService.recentlyViewedSessionIDs()
      .filter { knownSessionIDs.contains($0) }
  }

  private func appendFallbackRecentSessionIDs(to sessionIDs: inout [String]) {
    var seen = Set(sessionIDs)
    for summary in sessionIndex.catalog.recentSessions {
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
