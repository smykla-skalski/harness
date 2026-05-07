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

  @Test("Register and unregister mutate the in-memory open window set")
  func registerAndUnregisterSessionWindowMutatesInMemorySet() {
    let store = makeStore()
    store.registerOpenSessionWindow(sessionID: "sess-a")
    store.registerOpenSessionWindow(sessionID: "sess-b")
    #expect(store.openSessionWindowIDsSnapshot == ["sess-a", "sess-b"])

    store.unregisterOpenSessionWindow(sessionID: "sess-a")
    #expect(store.openSessionWindowIDsSnapshot == ["sess-b"])
  }

  @Test("Begin termination snapshot freezes the live registry for later flush")
  func beginTerminationSnapshotFreezesRegistry() async {
    let store = makeStore(cacheService: cacheService)
    let defaults = try! isolatedDefaults()
    defer { defaults.userDefaults.removePersistentDomain(forName: defaults.suiteName) }

    store.registerOpenSessionWindow(sessionID: "sess-a")
    store.registerOpenSessionWindow(sessionID: "sess-b")
    store.beginSessionWindowTerminationSnapshot()
    store.unregisterOpenSessionWindow(sessionID: "sess-a")
    store.unregisterOpenSessionWindow(sessionID: "sess-b")

    await store.flushSessionWindowsOpenAtQuit(userDefaults: defaults.userDefaults)

    let ids = await cacheService.sessionWindowIDsOpenAtQuit(limit: 10)
    #expect(Set(ids) == ["sess-a", "sess-b"])
  }

  @Test("Flush without a snapshot uses the current registry contents")
  func flushWithoutSnapshotUsesCurrentRegistry() async {
    let store = makeStore(cacheService: cacheService)
    let defaults = try! isolatedDefaults()
    defer { defaults.userDefaults.removePersistentDomain(forName: defaults.suiteName) }

    store.registerOpenSessionWindow(sessionID: "sess-a")
    await store.flushSessionWindowsOpenAtQuit(userDefaults: defaults.userDefaults)

    let ids = await cacheService.sessionWindowIDsOpenAtQuit(limit: 10)
    #expect(Set(ids) == ["sess-a"])
    #expect(defaults.userDefaults.bool(forKey: HarnessMonitorStore.launchWindowBridgeFallbackKey))
  }

  @Test("Bridge fallback runs once when wasOpenAtQuit is empty")
  func bridgeFallbackRunsOnceWhenWasOpenAtQuitIsEmpty() async {
    let store = makeStore(cacheService: cacheService)
    let defaults = try! isolatedDefaults()
    defer { defaults.userDefaults.removePersistentDomain(forName: defaults.suiteName) }

    let firstResult = await store.recentSessionIDsForLaunchWindows(
      limit: 4,
      userDefaults: defaults.userDefaults
    )
    #expect(firstResult.isEmpty)
    #expect(defaults.userDefaults.bool(forKey: HarnessMonitorStore.launchWindowBridgeFallbackKey))

    let secondResult = await store.recentSessionIDsForLaunchWindows(
      limit: 4,
      userDefaults: defaults.userDefaults
    )
    #expect(secondResult.isEmpty)
  }

  @Test("Existing wasOpenAtQuit rows suppress the bridge fallback even if catalog filters them out")
  func priorWasOpenAtQuitRowsSuppressBridgeFallback() async {
    _ = await cacheService.replaceSessionWindowsOpenAtQuit(sessionIDs: ["sess-a"])
    let store = makeStore(cacheService: cacheService)

    let defaults = try! isolatedDefaults()
    defer { defaults.userDefaults.removePersistentDomain(forName: defaults.suiteName) }

    let result = await store.recentSessionIDsForLaunchWindows(
      limit: 4,
      userDefaults: defaults.userDefaults
    )
    // sess-a is filtered out by the empty session catalog, so the visible
    // result is empty, but the raw cache still has a row — the bridge must
    // not run and the bridge flag stays unset.
    #expect(result.isEmpty)
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
