import Foundation

extension HarnessMonitorStore {
  public static let launchWindowBridgeFallbackKey =
    "harness.monitor.launch-window.bridge-fallback-done"

  /// A snapshot of one tab group at quit. `sessionIDs` is ordered by the
  /// tab position the user saw left-to-right; `foregroundSessionID` is the
  /// selected tab if the group had one, otherwise nil (replay falls back
  /// to the first session).
  public struct SessionTabGroupSnapshot: Equatable, Sendable {
    public let ordinal: Int
    public let sessionIDs: [String]
    public let foregroundSessionID: String?

    public init(
      ordinal: Int,
      sessionIDs: [String],
      foregroundSessionID: String? = nil
    ) {
      self.ordinal = ordinal
      self.sessionIDs = sessionIDs
      self.foregroundSessionID = foregroundSessionID
    }
  }

  /// Snapshot of every session window observed at termination, with tab
  /// grouping information so the launch path can re-merge tabs that were
  /// grouped together. `groupings` only includes groups with >1 member;
  /// standalone session windows live in `sessionIDs` without a grouping
  /// entry.
  public struct SessionWindowQuitSnapshot: Equatable, Sendable {
    public let sessionIDs: Set<String>
    public let groupings: [SessionTabGroupSnapshot]

    public init(
      sessionIDs: Set<String> = [],
      groupings: [SessionTabGroupSnapshot] = []
    ) {
      self.sessionIDs = sessionIDs
      self.groupings = groupings
    }
  }

  public struct LaunchWindowRestorePlan: Equatable, Sendable {
    public let sessionIDs: [String]
    public let usedBridgeFallback: Bool
    public let tabGroupings: [SessionTabGroupSnapshot]

    public init(
      sessionIDs: [String] = [],
      usedBridgeFallback: Bool = false,
      tabGroupings: [SessionTabGroupSnapshot] = []
    ) {
      self.sessionIDs = sessionIDs
      self.usedBridgeFallback = usedBridgeFallback
      self.tabGroupings = tabGroupings
    }
  }

  public func launchWindowRestorePlan(
    userDefaults: UserDefaults = .standard
  ) async -> LaunchWindowRestorePlan {
    let openAtQuit = await sessionWindowIDsOpenAtQuit()
    if !openAtQuit.isEmpty {
      let groupings = await sessionTabGroupsAtQuit()
      let knownSessionIDs = Set(openAtQuit)
      let filteredGroupings = filterTabGroupings(
        groupings,
        knownSessionIDs: knownSessionIDs
      )
      let orderedSessionIDs = orderedRestoreSessionIDs(
        openAtQuit,
        groupings: filteredGroupings
      )
      return LaunchWindowRestorePlan(
        sessionIDs: orderedSessionIDs,
        tabGroupings: filteredGroupings
      )
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

  /// Tab grouping rows can outlive their referenced session catalog (e.g.
  /// after a recent-sessions cleanup). Drop members that no longer have a
  /// session in the active catalog and discard groups whose surviving
  /// members would be <2 - those are effectively standalone now.
  private func filterTabGroupings(
    _ groupings: [SessionTabGroupSnapshot],
    knownSessionIDs: Set<String>
  ) -> [SessionTabGroupSnapshot] {
    var filtered: [SessionTabGroupSnapshot] = []
    for grouping in groupings {
      let survivors = grouping.sessionIDs.filter { knownSessionIDs.contains($0) }
      guard survivors.count > 1 else { continue }
      let foreground =
        survivors.contains(where: { $0 == grouping.foregroundSessionID })
        ? grouping.foregroundSessionID
        : nil
      filtered.append(
        SessionTabGroupSnapshot(
          ordinal: grouping.ordinal,
          sessionIDs: survivors,
          foregroundSessionID: foreground
        )
      )
    }
    return filtered
  }

  private func orderedRestoreSessionIDs(
    _ openAtQuit: [String],
    groupings: [SessionTabGroupSnapshot]
  ) -> [String] {
    var ordered: [String] = []
    var seen: Set<String> = []
    for grouping in groupings.sorted(by: { $0.ordinal < $1.ordinal }) {
      for sessionID in grouping.sessionIDs where seen.insert(sessionID).inserted {
        ordered.append(sessionID)
      }
    }
    for sessionID in openAtQuit where seen.insert(sessionID).inserted {
      ordered.append(sessionID)
    }
    return ordered
  }

  private func sessionTabGroupsAtQuit() async -> [SessionTabGroupSnapshot] {
    guard let cacheService else { return [] }
    return await cacheService.sessionTabGroupsAtQuit()
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

  public func sessionID(forOpenSessionWindowID windowID: ObjectIdentifier) -> String? {
    openSessionWindowsByID[windowID]
  }

  public func beginSessionWindowTerminationSnapshot() {
    pendingSessionWindowTerminationSnapshot = openSessionWindowIDsSnapshot
  }

  public func beginSessionWindowTerminationSnapshot(
    quitSnapshot: SessionWindowQuitSnapshot
  ) {
    pendingSessionWindowTerminationSnapshot = quitSnapshot.sessionIDs
    pendingSessionWindowQuitSnapshot = quitSnapshot
  }

  public func flushSessionWindowsOpenAtQuit() async {
    await flushSessionWindowsOpenAtQuit(userDefaults: .standard)
  }

  func flushSessionWindowsOpenAtQuit(userDefaults: UserDefaults) async {
    let sessionIDs = pendingSessionWindowTerminationSnapshot ?? openSessionWindowIDsSnapshot
    let pendingQuit = pendingSessionWindowQuitSnapshot
    pendingSessionWindowTerminationSnapshot = nil
    pendingSessionWindowQuitSnapshot = nil
    guard let cacheService, persistenceError == nil else { return }
    let snapshot =
      pendingQuit
      ?? SessionWindowQuitSnapshot(sessionIDs: sessionIDs)
    _ = await cacheService.replaceSessionWindowsOpenAtQuit(snapshot: snapshot)
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
