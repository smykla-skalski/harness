import Foundation
import SwiftData
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Launch window state migration")
struct LaunchWindowRestorerMigratorTests {
  let container: ModelContainer
  let cacheService: SessionCacheService

  init() throws {
    container = try HarnessMonitorModelContainer.preview()
    cacheService = SessionCacheService(modelContainer: container)
  }

  @Test("Replace flips wasOpenAtQuit rows and removes ones not in the snapshot")
  func replaceSessionWindowsOpenAtQuitOverwritesPriorRows() async {
    _ = await cacheService.replaceSessionWindowsOpenAtQuit(
      sessionIDs: ["sess-a", "sess-b"]
    )
    var ids = await cacheService.sessionWindowIDsOpenAtQuit(limit: 10)
    #expect(Set(ids) == ["sess-a", "sess-b"])

    _ = await cacheService.replaceSessionWindowsOpenAtQuit(
      sessionIDs: ["sess-b", "sess-c"]
    )
    ids = await cacheService.sessionWindowIDsOpenAtQuit(limit: 10)
    #expect(Set(ids) == ["sess-b", "sess-c"])

    _ = await cacheService.replaceSessionWindowsOpenAtQuit(sessionIDs: [])
    ids = await cacheService.sessionWindowIDsOpenAtQuit(limit: 10)
    #expect(ids.isEmpty)
  }

  @Test("Register and unregister mutate the in-memory open window registry")
  func registerAndUnregisterSessionWindowMutatesInMemorySet() {
    let store = makeStore()
    let firstWindow = NSObject()
    let secondWindow = NSObject()
    let duplicateSessionWindow = NSObject()
    let firstWindowID = ObjectIdentifier(firstWindow)
    let secondWindowID = ObjectIdentifier(secondWindow)
    let duplicateSessionWindowID = ObjectIdentifier(duplicateSessionWindow)
    store.registerOpenSessionWindow(windowID: firstWindowID, sessionID: "sess-a")
    store.registerOpenSessionWindow(windowID: secondWindowID, sessionID: "sess-b")
    store.registerOpenSessionWindow(windowID: duplicateSessionWindowID, sessionID: "sess-b")
    #expect(store.openSessionWindowIDsSnapshot == ["sess-a", "sess-b"])

    store.unregisterOpenSessionWindow(windowID: firstWindowID)
    #expect(store.openSessionWindowIDsSnapshot == ["sess-b"])
    store.unregisterOpenSessionWindow(windowID: secondWindowID)
    #expect(store.openSessionWindowIDsSnapshot == ["sess-b"])
    store.unregisterOpenSessionWindow(windowID: duplicateSessionWindowID)
    #expect(store.openSessionWindowIDsSnapshot.isEmpty)
  }

  @Test("Begin termination snapshot freezes the live registry for later flush")
  func beginTerminationSnapshotFreezesRegistry() async throws {
    let store = makeStore(cacheService: cacheService)
    let defaults = try isolatedDefaults()
    defer { defaults.userDefaults.removePersistentDomain(forName: defaults.suiteName) }

    let firstWindow = NSObject()
    let secondWindow = NSObject()
    let firstWindowID = ObjectIdentifier(firstWindow)
    let secondWindowID = ObjectIdentifier(secondWindow)
    store.registerOpenSessionWindow(windowID: firstWindowID, sessionID: "sess-a")
    store.registerOpenSessionWindow(windowID: secondWindowID, sessionID: "sess-b")
    store.beginSessionWindowTerminationSnapshot()
    store.unregisterOpenSessionWindow(windowID: firstWindowID)
    store.unregisterOpenSessionWindow(windowID: secondWindowID)

    await store.flushSessionWindowsOpenAtQuit(userDefaults: defaults.userDefaults)

    let ids = await cacheService.sessionWindowIDsOpenAtQuit(limit: 10)
    #expect(Set(ids) == ["sess-a", "sess-b"])
  }

  @Test("Empty AppKit quit snapshot still preserves open session windows at termination")
  func emptyQuitSnapshotFallsBackToOpenSessionWindows() async throws {
    let store = makeStore(cacheService: cacheService)
    let defaults = try isolatedDefaults()
    defer { defaults.userDefaults.removePersistentDomain(forName: defaults.suiteName) }

    let firstWindow = NSObject()
    let secondWindow = NSObject()
    let firstWindowID = ObjectIdentifier(firstWindow)
    let secondWindowID = ObjectIdentifier(secondWindow)
    store.registerOpenSessionWindow(windowID: firstWindowID, sessionID: "sess-a")
    store.registerOpenSessionWindow(windowID: secondWindowID, sessionID: "sess-b")

    store.beginSessionWindowTerminationSnapshot(
      quitSnapshot: HarnessMonitorStore.SessionWindowQuitSnapshot()
    )
    store.unregisterOpenSessionWindow(windowID: firstWindowID)
    store.unregisterOpenSessionWindow(windowID: secondWindowID)

    await store.flushSessionWindowsOpenAtQuit(userDefaults: defaults.userDefaults)

    let ids = await cacheService.sessionWindowIDsOpenAtQuit(limit: 10)
    #expect(Set(ids) == ["sess-a", "sess-b"])
  }

  @Test("Flush without a snapshot uses the current registry contents")
  func flushWithoutSnapshotUsesCurrentRegistry() async throws {
    let store = makeStore(cacheService: cacheService)
    let defaults = try isolatedDefaults()
    defer { defaults.userDefaults.removePersistentDomain(forName: defaults.suiteName) }

    let window = NSObject()
    store.registerOpenSessionWindow(windowID: ObjectIdentifier(window), sessionID: "sess-a")
    await store.flushSessionWindowsOpenAtQuit(userDefaults: defaults.userDefaults)

    let ids = await cacheService.sessionWindowIDsOpenAtQuit(limit: 10)
    #expect(Set(ids) == ["sess-a"])
    #expect(defaults.userDefaults.bool(forKey: HarnessMonitorStore.launchWindowBridgeFallbackKey))
  }

  @Test("Bridge fallback remains pending until launch routing completes")
  func bridgeFallbackRunsOnceWhenWasOpenAtQuitIsEmpty() async throws {
    let store = makeStore(cacheService: cacheService)
    let defaults = try isolatedDefaults()
    defer { defaults.userDefaults.removePersistentDomain(forName: defaults.suiteName) }

    let firstPlan = await store.launchWindowRestorePlan(
      userDefaults: defaults.userDefaults
    )
    #expect(firstPlan.sessionIDs.isEmpty)
    #expect(firstPlan.usedBridgeFallback)
    #expect(!defaults.userDefaults.bool(forKey: HarnessMonitorStore.launchWindowBridgeFallbackKey))

    store.completeLaunchWindowBridgeFallback(userDefaults: defaults.userDefaults)
    #expect(defaults.userDefaults.bool(forKey: HarnessMonitorStore.launchWindowBridgeFallbackKey))

    let secondPlan = await store.launchWindowRestorePlan(
      userDefaults: defaults.userDefaults
    )
    #expect(secondPlan.sessionIDs.isEmpty)
    #expect(!secondPlan.usedBridgeFallback)
  }

  @Test("Existing wasOpenAtQuit rows suppress the bridge fallback even if catalog filters them out")
  func priorWasOpenAtQuitRowsSuppressBridgeFallback() async throws {
    _ = await cacheService.replaceSessionWindowsOpenAtQuit(sessionIDs: ["sess-a"])
    let store = makeStore(cacheService: cacheService)

    let defaults = try isolatedDefaults()
    defer { defaults.userDefaults.removePersistentDomain(forName: defaults.suiteName) }

    let plan = await store.launchWindowRestorePlan(
      userDefaults: defaults.userDefaults
    )
    // sess-a is filtered out by the empty session catalog, so the visible
    // result is empty, but the raw cache still has a row — the bridge must
    // not run and the bridge flag stays unset.
    #expect(plan.sessionIDs.isEmpty)
    #expect(!plan.usedBridgeFallback)
    #expect(!defaults.userDefaults.bool(forKey: HarnessMonitorStore.launchWindowBridgeFallbackKey))
  }

  @Test("Snapshot with tab grouping round-trips through the cache layer")
  func quitSnapshotPreservesTabGroupings() async {
    let snapshot = HarnessMonitorStore.SessionWindowQuitSnapshot(
      sessionIDs: ["sess-a", "sess-b", "sess-c", "sess-d"],
      groupings: [
        HarnessMonitorStore.SessionTabGroupSnapshot(
          ordinal: 0,
          sessionIDs: ["sess-a", "sess-b"],
          foregroundSessionID: "sess-b"
        ),
        HarnessMonitorStore.SessionTabGroupSnapshot(
          ordinal: 1,
          sessionIDs: ["sess-c", "sess-d"],
          foregroundSessionID: nil
        ),
      ]
    )
    _ = await cacheService.replaceSessionWindowsOpenAtQuit(snapshot: snapshot)

    let groups = await cacheService.sessionTabGroupsAtQuit()
    #expect(groups.count == 2)
    let groupA = groups.first(where: { $0.sessionIDs.contains("sess-a") })
    #expect(groupA?.sessionIDs == ["sess-a", "sess-b"])
    #expect(groupA?.foregroundSessionID == "sess-b")
    let groupC = groups.first(where: { $0.sessionIDs.contains("sess-c") })
    #expect(groupC?.sessionIDs == ["sess-c", "sess-d"])
    #expect(groupC?.foregroundSessionID == nil)
  }

  @Test("Restore plan opens grouped sessions in saved tab order before standalone windows")
  func restorePlanUsesSavedTabOrderForGroupedSessions() async throws {
    let groupedLeader = PreviewFixtures.summary
    let groupedFollower = PreviewFixtures.signalRegressionSecondarySummary
    let groupedTail = try #require(
      PreviewFixtures.overflowSessions.first {
        $0.sessionId != groupedLeader.sessionId
          && $0.sessionId != groupedFollower.sessionId
      }
    )
    let standalone = try #require(
      PreviewFixtures.overflowSessions.first {
        $0.sessionId != groupedLeader.sessionId
          && $0.sessionId != groupedFollower.sessionId
          && $0.sessionId != groupedTail.sessionId
      }
    )
    let store = makeStore(cacheService: cacheService)

    for summary in [groupedLeader, groupedFollower, groupedTail, standalone] {
      #expect(store.sessionIndex.applySessionSummary(summary))
    }

    let groupedIDs = [
      groupedTail.sessionId,
      groupedLeader.sessionId,
      groupedFollower.sessionId,
    ]
    _ = await cacheService.replaceSessionWindowsOpenAtQuit(
      snapshot: HarnessMonitorStore.SessionWindowQuitSnapshot(
        sessionIDs: Set(groupedIDs + [standalone.sessionId]),
        groupings: [
          HarnessMonitorStore.SessionTabGroupSnapshot(
            ordinal: 0,
            sessionIDs: groupedIDs,
            foregroundSessionID: groupedLeader.sessionId
          )
        ]
      )
    )

    let plan = await store.launchWindowRestorePlan()

    #expect(plan.sessionIDs == groupedIDs + [standalone.sessionId])
    #expect(
      plan.tabGroupings == [
        HarnessMonitorStore.SessionTabGroupSnapshot(
          ordinal: 0,
          sessionIDs: groupedIDs,
          foregroundSessionID: groupedLeader.sessionId
        )
      ]
    )
  }

  @Test("Standalone session windows survive the snapshot without a grouping entry")
  func standaloneWindowsHaveNoGrouping() async {
    let snapshot = HarnessMonitorStore.SessionWindowQuitSnapshot(
      sessionIDs: ["sess-solo-1", "sess-solo-2"],
      groupings: []
    )
    _ = await cacheService.replaceSessionWindowsOpenAtQuit(snapshot: snapshot)

    let groups = await cacheService.sessionTabGroupsAtQuit()
    #expect(groups.isEmpty)
    let ids = await cacheService.sessionWindowIDsOpenAtQuit(limit: 10)
    #expect(Set(ids) == ["sess-solo-1", "sess-solo-2"])
  }

  @Test("Replacing an existing snapshot drops stale tab grouping rows")
  func replacingSnapshotResetsTabGrouping() async {
    let initial = HarnessMonitorStore.SessionWindowQuitSnapshot(
      sessionIDs: ["sess-a", "sess-b"],
      groupings: [
        HarnessMonitorStore.SessionTabGroupSnapshot(
          ordinal: 0,
          sessionIDs: ["sess-a", "sess-b"],
          foregroundSessionID: "sess-a"
        )
      ]
    )
    _ = await cacheService.replaceSessionWindowsOpenAtQuit(snapshot: initial)

    let cleared = HarnessMonitorStore.SessionWindowQuitSnapshot(
      sessionIDs: ["sess-a", "sess-b"],
      groupings: []
    )
    _ = await cacheService.replaceSessionWindowsOpenAtQuit(snapshot: cleared)

    let groups = await cacheService.sessionTabGroupsAtQuit()
    #expect(groups.isEmpty)
  }

  @Test("Legacy Set<String> overload preserves wasOpenAtQuit + clears any tab grouping")
  func legacySetOverloadHasNoGrouping() async {
    let initial = HarnessMonitorStore.SessionWindowQuitSnapshot(
      sessionIDs: ["sess-a", "sess-b"],
      groupings: [
        HarnessMonitorStore.SessionTabGroupSnapshot(
          ordinal: 0,
          sessionIDs: ["sess-a", "sess-b"],
          foregroundSessionID: nil
        )
      ]
    )
    _ = await cacheService.replaceSessionWindowsOpenAtQuit(snapshot: initial)

    _ = await cacheService.replaceSessionWindowsOpenAtQuit(
      sessionIDs: ["sess-a", "sess-b"]
    )

    let groups = await cacheService.sessionTabGroupsAtQuit()
    #expect(groups.isEmpty)
  }

  private func makeStore(cacheService: SessionCacheService? = nil) -> HarnessMonitorStore {
    HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      modelContainer: container,
      cacheService: cacheService
    )
  }

  private func isolatedDefaults() throws -> (userDefaults: UserDefaults, suiteName: String) {
    let suiteName = "LaunchWindowRestorerMigratorTests.\(UUID().uuidString)"
    let userDefaults = try #require(UserDefaults(suiteName: suiteName))
    userDefaults.removePersistentDomain(forName: suiteName)
    return (userDefaults, suiteName)
  }
}
