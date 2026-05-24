import Foundation
import SwiftData
import Testing
import XCTest

@testable import HarnessMonitorKit

@MainActor
extension PersistenceOfflineDurabilityTests {
  @Test("Offline bootstrap restores cached task-board items after relaunch")
  func offlineBootstrapRestoresCachedTaskBoardItemsAfterRelaunch() async throws {
    let githubItem = makeTaskBoardItem(
      id: "board-github",
      provider: .gitHub,
      externalId: "123"
    )
    let todoistItem = makeTaskBoardItem(
      id: "board-todoist",
      provider: .todoist,
      externalId: "456"
    )
    let orchestratorStatus = makeTaskBoardOrchestratorStatus()

    do {
      let liveStore = HarnessMonitorStore(
        daemonController: RecordingDaemonController(),
        modelContainer: previewContainer
      )
      await liveStore.cacheTaskBoardSnapshot(
        items: [githubItem, todoistItem],
        orchestratorStatus: orchestratorStatus
      )
    }

    let relaunchedStore = HarnessMonitorStore(
      daemonController: FailingDaemonController(
        bootstrapError: DaemonControlError.daemonOffline
      ),
      modelContainer: previewContainer
    )

    await relaunchedStore.bootstrap()

    #expect(
      relaunchedStore.connectionState
        == .offline(DaemonControlError.daemonOffline.localizedDescription)
    )
    #expect(relaunchedStore.globalTaskBoardItems.map(\.id) == ["board-github", "board-todoist"])
    #expect(
      relaunchedStore.globalTaskBoardItems.map(\.externalRefs.first?.provider)
        == [.gitHub, .todoist]
    )
    #expect(relaunchedStore.globalTaskBoardOrchestratorStatus == orchestratorStatus)
  }

  @Test("External bootstrap restores cached task-board items before daemon warm-up finishes")
  func externalBootstrapRestoresCachedTaskBoardItemsBeforeWarmUpFinishes() async throws {
    let githubItem = makeTaskBoardItem(
      id: "board-external-github",
      provider: .gitHub,
      externalId: "999"
    )
    let orchestratorStatus = makeTaskBoardOrchestratorStatus()

    do {
      let liveStore = HarnessMonitorStore(
        daemonController: RecordingDaemonController(),
        daemonOwnership: .external,
        modelContainer: previewContainer
      )
      await liveStore.cacheTaskBoardSnapshot(
        items: [githubItem],
        orchestratorStatus: orchestratorStatus
      )
    }

    let daemon = DelayedWarmUpDaemonController(warmUpDelay: .milliseconds(250))
    let relaunchedStore = HarnessMonitorStore(
      daemonController: daemon,
      daemonOwnership: .external,
      modelContainer: previewContainer
    )

    let bootstrapTask = Task { @MainActor in
      await relaunchedStore.bootstrap()
    }

    for _ in 0..<20 where relaunchedStore.globalTaskBoardItems.isEmpty {
      try await Task.sleep(for: .milliseconds(10))
    }

    #expect(relaunchedStore.connectionState == .connecting)
    #expect(relaunchedStore.globalTaskBoardItems.map(\.id) == ["board-external-github"])
    #expect(relaunchedStore.globalTaskBoardOrchestratorStatus == orchestratorStatus)

    await bootstrapTask.value
  }

  @Test(
    "Connecting restore keeps cached task-board items when connection state flips idle mid-hydration"
  )
  func connectingRestoreKeepsCachedTaskBoardItemsWhenConnectionTurnsIdle() async throws {
    let githubItem = makeTaskBoardItem(
      id: "board-connecting-github",
      provider: .gitHub,
      externalId: "321"
    )
    let orchestratorStatus = makeTaskBoardOrchestratorStatus()
    let store = makeStore()
    await store.cacheTaskBoardSnapshot(
      items: [githubItem],
      orchestratorStatus: orchestratorStatus
    )
    store.connectionState = .connecting

    let idleFlipTask = Task { @MainActor in
      await Task.yield()
      store.connectionState = .idle
    }

    await store.restorePersistedSessionStateWhileConnecting()
    await idleFlipTask.value

    #expect(store.globalTaskBoardItems.map(\.id) == ["board-connecting-github"])
    #expect(store.globalTaskBoardOrchestratorStatus == orchestratorStatus)
  }

  @Test("Refresh persists task-board snapshots even when session list caching also runs")
  func refreshPersistsTaskBoardSnapshotsAlongsideSessionListCaching() async {
    let client = RecordingHarnessClient()
    client.configureSessions(
      summaries: [PreviewFixtures.summary],
      detailsByID: [PreviewFixtures.summary.sessionId: PreviewFixtures.detail]
    )
    let githubItem = makeTaskBoardItem(
      id: "board-refresh-github",
      provider: .gitHub,
      externalId: "refresh-123"
    )
    let orchestratorStatus = client.sampleTaskBoardOrchestratorStatus()
    client.configureTaskBoardItems([githubItem])
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client),
      modelContainer: previewContainer
    )

    await store.refresh(using: client, preserveSelection: false)
    await store.flushPendingCacheWrite()

    let cachedSessions = await store.loadCachedSessionList()
    let cachedTaskBoard = await store.loadCachedTaskBoardSnapshot()

    #expect(cachedSessions?.sessions.map(\.sessionId) == [PreviewFixtures.summary.sessionId])
    #expect(cachedTaskBoard?.items.map(\.id) == ["board-refresh-github"])
    #expect(cachedTaskBoard?.items.map(\.externalRefs.first?.provider) == [.gitHub])
    #expect(cachedTaskBoard?.orchestratorStatus == orchestratorStatus)
  }

  @Test("Task-board snapshot caching survives a later generic cache write")
  func taskBoardSnapshotCachingSurvivesLaterGenericCacheWrite() async {
    let store = makeStore()
    let githubItem = makeTaskBoardItem(
      id: "board-queue-github",
      provider: .gitHub,
      externalId: "queue-123"
    )
    let orchestratorStatus = makeTaskBoardOrchestratorStatus()

    store.scheduleTaskBoardSnapshotCacheWrite(
      items: [githubItem],
      orchestratorStatus: orchestratorStatus
    )
    store.scheduleCacheWrite { service in
      await service.cacheSessionList([PreviewFixtures.summary], projects: PreviewFixtures.projects)
    }
    await store.flushPendingCacheWrite()

    let cachedSessions = await store.loadCachedSessionList()
    let cachedTaskBoard = await store.loadCachedTaskBoardSnapshot()

    #expect(cachedSessions?.sessions.map(\.sessionId) == [PreviewFixtures.summary.sessionId])
    #expect(cachedTaskBoard?.items.map(\.id) == ["board-queue-github"])
    #expect(cachedTaskBoard?.orchestratorStatus == orchestratorStatus)
  }

  @Test("Restore keeps live task-board items when the persisted snapshot is stale")
  func restoreKeepsLiveTaskBoardItemsWhenPersistedSnapshotIsStale() async throws {
    let persistedItem = makeTaskBoardItem(
      id: "board-persisted",
      provider: .gitHub,
      externalId: "persisted"
    )
    let liveItem = makeTaskBoardItem(
      id: "board-live",
      provider: .todoist,
      externalId: "live"
    )
    let store = makeStore()
    await store.cacheTaskBoardSnapshot(
      items: [persistedItem],
      orchestratorStatus: makeTaskBoardOrchestratorStatus()
    )
    store.globalTaskBoardItems = [liveItem]
    store.connectionState = .offline("daemon down")

    await store.restorePersistedSessionState()

    #expect(store.globalTaskBoardItems.map(\.id) == ["board-live"])
    #expect(store.globalTaskBoardItems.first?.externalRefs.first?.provider == .todoist)
  }

  @Test("Offline mode keeps local bookmarks notes filters and search history editable")
  func offlineModeKeepsLocalOnlyDataEditable() async throws {
    let store = makeStore()
    store.connectionState = .offline("daemon down")

    #expect(await store.toggleBookmark(sessionId: "sess-offline", projectId: "proj-1"))
    #expect(store.isBookmarked(sessionId: "sess-offline"))

    #expect(
      await store.addNote(
        text: "Offline note",
        targetKind: "task",
        targetId: "task-offline",
        sessionId: "sess-offline"
      ))

    store.sessionFilter = .ended
    store.sessionFocusFilter = .blocked
    await store.saveFilterPreference(for: "proj-offline")
    store.sessionFilter = .active
    store.sessionFocusFilter = .all
    await store.loadFilterPreference(for: "proj-offline")

    #expect(await store.recordSearch("offline cockpit"))

    let notes = try fetchNotes(targetId: "task-offline", sessionId: "sess-offline")
    let searches = try fetchRecentSearches()

    #expect(notes.count == 1)
    #expect(notes.first?.text == "Offline note")
    #expect(searches.count == 1)
    #expect(searches.first?.query == "offline cockpit")
    #expect(store.sessionFilter == .ended)
    #expect(store.sessionFocusFilter == .blocked)
  }
}
