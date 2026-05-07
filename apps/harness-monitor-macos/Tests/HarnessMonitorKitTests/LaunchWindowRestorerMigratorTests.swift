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
