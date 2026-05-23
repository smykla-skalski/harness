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
    public let includesDashboard: Bool
    public let dashboardWasForeground: Bool

    public init(
      ordinal: Int,
      sessionIDs: [String],
      foregroundSessionID: String? = nil,
      includesDashboard: Bool = false,
      dashboardWasForeground: Bool = false
    ) {
      self.ordinal = ordinal
      self.sessionIDs = sessionIDs
      self.foregroundSessionID = foregroundSessionID
      self.includesDashboard = includesDashboard
      self.dashboardWasForeground = dashboardWasForeground
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
    let knownSessionIDs = sessionIndex.catalog.sessionIDs
    let fallbackRecentSessionIDs = sessionIndex.catalog.recentSessionIDs
    let openAtQuit = await rawSessionWindowIDsOpenAtQuit()
    if !openAtQuit.isEmpty {
      let groupings = await sessionTabGroupsAtQuit()
      return await launchWindowRestoreWorker.openAtQuitPlan(
        openAtQuit: openAtQuit,
        groupings: groupings,
        knownSessionIDs: knownSessionIDs
      )
    }
    let hasPriorWindowState = await rawSessionWindowsOpenAtQuitExist()
    if hasPriorWindowState || hasCompletedLaunchWindowBridgeFallback(userDefaults: userDefaults) {
      return LaunchWindowRestorePlan()
    }
    let bridgedIDs = await rawRecentlyViewedSessionIDs()
    return await launchWindowRestoreWorker.bridgeFallbackPlan(
      recentlyViewedSessionIDs: bridgedIDs,
      fallbackRecentSessionIDs: fallbackRecentSessionIDs,
      knownSessionIDs: knownSessionIDs
    )
  }

  /// Tab grouping rows can outlive their referenced session catalog (e.g.
  /// after a recent-sessions cleanup). Drop members that no longer have a
  /// session in the active catalog and discard groups whose surviving
  /// members would be <2 - those are effectively standalone now.
  nonisolated static func filterTabGroupings(
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

  nonisolated static func orderedRestoreSessionIDs(
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
    let resolvedQuitSnapshot = resolvedSessionWindowQuitSnapshot(quitSnapshot)
    pendingSessionWindowTerminationSnapshot = resolvedQuitSnapshot.sessionIDs
    pendingSessionWindowQuitSnapshot = resolvedQuitSnapshot
  }

  public func flushSessionWindowsOpenAtQuit() async {
    await flushSessionWindowsOpenAtQuit(userDefaults: .standard)
  }

  public func persistSessionWindowRestoreSnapshot(
    _ snapshot: SessionWindowQuitSnapshot,
    userDefaults: UserDefaults = .standard
  ) async {
    guard let cacheService, persistenceError == nil else { return }
    _ = await cacheService.replaceSessionWindowsOpenAtQuit(snapshot: snapshot)
    markLaunchWindowBridgeFallbackComplete(userDefaults: userDefaults)
  }

  func flushSessionWindowsOpenAtQuit(userDefaults: UserDefaults) async {
    let sessionIDs = pendingSessionWindowTerminationSnapshot ?? openSessionWindowIDsSnapshot
    let pendingQuit = pendingSessionWindowQuitSnapshot
    pendingSessionWindowTerminationSnapshot = nil
    pendingSessionWindowQuitSnapshot = nil
    let snapshot =
      pendingQuit
      ?? SessionWindowQuitSnapshot(sessionIDs: sessionIDs)
    await persistSessionWindowRestoreSnapshot(snapshot, userDefaults: userDefaults)
  }

  private func rawSessionWindowIDsOpenAtQuit() async -> [String] {
    guard let cacheService else { return [] }
    return await cacheService.sessionWindowIDsOpenAtQuit()
  }

  private func rawRecentlyViewedSessionIDs() async -> [String] {
    guard let cacheService else { return [] }
    return await cacheService.recentlyViewedSessionIDs()
  }

  private func resolvedSessionWindowQuitSnapshot(
    _ quitSnapshot: SessionWindowQuitSnapshot
  ) -> SessionWindowQuitSnapshot {
    SessionWindowQuitSnapshot(
      sessionIDs: quitSnapshot.sessionIDs.union(openSessionWindowIDsSnapshot),
      groupings: quitSnapshot.groupings
    )
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

actor LaunchWindowRestoreWorker {
  func openAtQuitPlan(
    openAtQuit: [String],
    groupings: [HarnessMonitorStore.SessionTabGroupSnapshot],
    knownSessionIDs: Set<String>
  ) -> HarnessMonitorStore.LaunchWindowRestorePlan {
    let filteredOpenAtQuit = openAtQuit.filter { knownSessionIDs.contains($0) }
    let filteredGroupings = HarnessMonitorStore.filterTabGroupings(
      groupings,
      knownSessionIDs: knownSessionIDs
    )
    return HarnessMonitorStore.LaunchWindowRestorePlan(
      sessionIDs: HarnessMonitorStore.orderedRestoreSessionIDs(
        filteredOpenAtQuit,
        groupings: filteredGroupings
      ),
      tabGroupings: filteredGroupings
    )
  }

  func bridgeFallbackPlan(
    recentlyViewedSessionIDs: [String],
    fallbackRecentSessionIDs: [String],
    knownSessionIDs: Set<String>
  ) -> HarnessMonitorStore.LaunchWindowRestorePlan {
    var sessionIDs = recentlyViewedSessionIDs.filter { knownSessionIDs.contains($0) }
    var seen = Set(sessionIDs)
    for sessionID in fallbackRecentSessionIDs where knownSessionIDs.contains(sessionID) {
      guard seen.insert(sessionID).inserted else {
        continue
      }
      sessionIDs.append(sessionID)
    }
    return HarnessMonitorStore.LaunchWindowRestorePlan(
      sessionIDs: sessionIDs,
      usedBridgeFallback: true
    )
  }

  func waitForIdle() {}
}
