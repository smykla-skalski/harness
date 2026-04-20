import Foundation
import SwiftData
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Persistence offline durability")
struct PersistenceOfflineDurabilityTests {
  let previewContainer: ModelContainer

  init() throws {
    previewContainer = try HarnessMonitorModelContainer.preview()
  }

  private func makeStore() -> HarnessMonitorStore {
    HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      modelContainer: previewContainer
    )
  }

  private func fetchNotes(
    targetId: String,
    sessionId: String
  ) throws -> [UserNote] {
    let notes = try previewContainer.mainContext.fetch(FetchDescriptor<UserNote>())
    return
      notes
      .filter { $0.targetId == targetId && $0.sessionId == sessionId }
      .sorted { $0.createdAt > $1.createdAt }
  }

  private func fetchRecentSearches() throws -> [RecentSearch] {
    try previewContainer.mainContext.fetch(
      FetchDescriptor<RecentSearch>(
        sortBy: [SortDescriptor(\RecentSearch.lastUsedAt, order: .reverse)]
      ))
  }

  private func makeV1Container(at url: URL) throws -> ModelContainer {
    let schema = Schema(versionedSchema: HarnessMonitorSchemaV1.self)
    let config = ModelConfiguration("HarnessMonitorStore", schema: schema, url: url)
    return try ModelContainer(for: schema, configurations: [config])
  }

  private func seedV1Store(
    at url: URL,
    metricsData: Data,
    sessionCount: Int = 1
  ) throws {
    let container = try makeV1Container(at: url)
    let project = HarnessMonitorSchemaV1.CachedProject(
      projectId: "proj-1",
      name: "Harness",
      projectDir: "/tmp/harness",
      contextRoot: "/tmp/harness-context",
      activeSessionCount: 1,
      totalSessionCount: sessionCount
    )

    container.mainContext.insert(project)
    for index in 0..<sessionCount {
      let session = HarnessMonitorSchemaV1.CachedSession(
        sessionId: sessionCount == 1 ? "sess-1" : "sess-\(index)",
        projectId: "proj-1",
        projectName: "Harness",
        projectDir: "/tmp/harness",
        contextRoot: "/tmp/harness-context",
        context: sessionCount == 1 ? "Migrated session" : "Migrated session \(index)",
        statusRaw: SessionStatus.active.rawValue,
        createdAt: "2026-04-03T12:00:00Z",
        updatedAt: "2026-04-03T12:05:00Z",
        lastActivityAt: "2026-04-03T12:05:00Z",
        leaderId: sessionCount == 1 ? "leader-1" : "leader-\(index)",
        observeId: sessionCount == 1 ? "observe-1" : "observe-\(index)",
        metricsData: metricsData
      )
      container.mainContext.insert(session)
    }

    try container.mainContext.save()
  }

  @Test("Stopping the daemon keeps the selected persisted snapshot readable")
  func stopDaemonKeepsSelectedPersistedSnapshotReadable() async throws {
    let client = RecordingHarnessClient()
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client),
      modelContainer: previewContainer
    )

    await store.bootstrap()
    await store.selectSession(PreviewFixtures.summary.sessionId)
    let cachedTimeline = store.timeline

    await store.stopDaemon()

    #expect(store.connectionState == .offline("Daemon stopped"))
    #expect(store.selectedSession?.session.sessionId == PreviewFixtures.summary.sessionId)
    #expect(store.timeline == cachedTimeline)
    #expect(store.isShowingCachedData)

    switch store.sessionDataAvailability {
    case .persisted(let reason, let sessionCount, let lastSnapshotAt):
      #expect(sessionCount == 1)
      #expect(lastSnapshotAt != nil)
      switch reason {
      case .daemonOffline(let message):
        #expect(message == "Daemon stopped")
      case .liveDataUnavailable:
        Issue.record("Expected stopDaemon() to expose daemonOffline persisted state")
      }
    case .live, .unavailable:
      Issue.record("Expected stopDaemon() to keep persisted session data readable")
    }
  }

  @Test("Offline bootstrap restores a persisted selection after relaunch-style state restore")
  func offlineBootstrapRestoresPersistedSelectionAfterRelaunch() async throws {
    let session = PreviewFixtures.summary
    let detail = PreviewFixtures.detail
    let timeline = PreviewFixtures.timeline

    do {
      let liveStore = HarnessMonitorStore(
        daemonController: RecordingDaemonController(),
        modelContainer: previewContainer
      )
      await liveStore.cacheSessionList([session], projects: PreviewFixtures.projects)
      await liveStore.cacheSessionDetail(detail, timeline: timeline, markViewed: false)
    }

    let relaunchedStore = HarnessMonitorStore(
      daemonController: FailingDaemonController(
        bootstrapError: DaemonControlError.daemonOffline
      ),
      modelContainer: previewContainer
    )
    relaunchedStore.selectedSessionID = session.sessionId

    await relaunchedStore.bootstrap()

    #expect(
      relaunchedStore.connectionState
        == .offline(DaemonControlError.daemonOffline.localizedDescription)
    )
    #expect(relaunchedStore.sessions == [session])
    #expect(relaunchedStore.selectedSession?.session.sessionId == session.sessionId)
    #expect(
      relaunchedStore.timeline.map(\.entryId).sorted()
        == timeline.map(\.entryId).sorted()
    )
    #expect(relaunchedStore.isShowingCachedData)
  }

  @Test("Offline mode keeps local bookmarks notes filters and search history editable")
  func offlineModeKeepsLocalOnlyDataEditable() throws {
    let store = makeStore()
    store.connectionState = .offline("daemon down")

    #expect(store.toggleBookmark(sessionId: "sess-offline", projectId: "proj-1"))
    #expect(store.isBookmarked(sessionId: "sess-offline"))

    #expect(
      store.addNote(
        text: "Offline note",
        targetKind: "task",
        targetId: "task-offline",
        sessionId: "sess-offline"
      ))

    store.sessionFilter = .ended
    store.sessionFocusFilter = .blocked
    store.saveFilterPreference(for: "proj-offline")
    store.sessionFilter = .active
    store.sessionFocusFilter = .all
    store.loadFilterPreference(for: "proj-offline")

    #expect(store.recordSearch("offline cockpit"))

    let notes = try fetchNotes(targetId: "task-offline", sessionId: "sess-offline")
    let searches = try fetchRecentSearches()

    #expect(notes.count == 1)
    #expect(notes.first?.text == "Offline note")
    #expect(searches.count == 1)
    #expect(searches.first?.query == "offline cockpit")
    #expect(store.sessionFilter == .ended)
    #expect(store.sessionFocusFilter == .blocked)
  }

  @Test("Live SwiftData store reopens persisted sessions across store recreation")
  func liveStoreReopensPersistedSessionsAcrossStoreRecreation() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let environment = HarnessMonitorEnvironment(
      values: ["XDG_DATA_HOME": root.path],
      homeDirectory: root
    )

    do {
      let firstContainer = try HarnessMonitorModelContainer.live(using: environment)
      let firstStore = HarnessMonitorStore(
        daemonController: RecordingDaemonController(),
        modelContainer: firstContainer
      )
      await firstStore.cacheSessionList(
        [PreviewFixtures.summary], projects: PreviewFixtures.projects)
      await firstStore.cacheSessionDetail(
        PreviewFixtures.detail, timeline: PreviewFixtures.timeline)
    }

    let reopenedContainer = try HarnessMonitorModelContainer.live(using: environment)
    let reopenedStore = HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      modelContainer: reopenedContainer
    )

    let cachedList = await reopenedStore.loadCachedSessionList()
    let cachedDetail = await reopenedStore.loadCachedSessionDetail(
      sessionID: PreviewFixtures.summary.sessionId
    )

    #expect(cachedList?.sessions == [PreviewFixtures.summary])
    #expect(cachedDetail?.detail.session.sessionId == PreviewFixtures.summary.sessionId)
    #expect(
      cachedDetail?.timeline.map(\.entryId).sorted()
        == PreviewFixtures.timeline.map(\.entryId).sorted()
    )
    await reopenedStore.refreshPersistedSessionMetadata()
    #expect(reopenedStore.persistedSessionCount == 1)
    #expect(reopenedStore.lastPersistedSnapshotAt != nil)
  }

  @Test("Live SwiftData store migrates V1 cache records into the current repo and worktree schema")
  func liveStoreMigratesV1CacheRecords() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let environment = HarnessMonitorEnvironment(
      values: ["XDG_DATA_HOME": root.path],
      homeDirectory: root
    )
    let harnessRoot = HarnessMonitorPaths.harnessRoot(using: environment)
    try FileManager.default.createDirectory(
      at: harnessRoot,
      withIntermediateDirectories: true,
      attributes: nil
    )

    let storeURL = harnessRoot.appendingPathComponent("harness-cache.store")
    let metricsData = try JSONEncoder().encode(
      SessionMetrics(
        agentCount: 2,
        activeAgentCount: 1,
        openTaskCount: 3,
        inProgressTaskCount: 1,
        blockedTaskCount: 0,
        completedTaskCount: 4
      ))

    try seedV1Store(at: storeURL, metricsData: metricsData)

    let container = try HarnessMonitorModelContainer.live(using: environment)
    let projects = try container.mainContext.fetch(FetchDescriptor<CachedProject>())
    let sessions = try container.mainContext.fetch(FetchDescriptor<CachedSession>())
    let migratedProject = projects.first?.toProjectSummary()
    let migratedSession = sessions.first?.toSessionSummary()

    #expect(projects.count == 1)
    #expect(migratedProject?.projectId == "proj-1")
    #expect(migratedProject?.worktrees == [])

    #expect(sessions.count == 1)
    #expect(migratedSession?.sessionId == "sess-1")
    #expect(migratedSession?.projectId == "proj-1")
    #expect(migratedSession?.worktreePath.isEmpty == true)
    #expect(migratedSession?.sharedPath.isEmpty == true)
    #expect(migratedSession?.branchRef.isEmpty == true)
    #expect(sessions.first?.metricsData == metricsData)
  }
}
