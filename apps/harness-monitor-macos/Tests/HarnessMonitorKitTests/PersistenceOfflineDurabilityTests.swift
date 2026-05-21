import Foundation
import SwiftData
import Testing
import XCTest

@testable import HarnessMonitorKit

// swiftlint:disable file_length
// swiftlint:disable type_body_length
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

  private func makeTaskBoardItem(
    id: String,
    provider: TaskBoardExternalRefProvider,
    externalId: String
  ) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: id,
      title: "Cache \(id)",
      body: "Persist external task-board entries",
      status: .todo,
      priority: .high,
      tags: ["cache"],
      projectId: "proj-task-board",
      agentMode: .interactive,
      externalRefs: [
        TaskBoardExternalRef(
          provider: provider,
          externalId: externalId,
          url: "https://example.invalid/\(externalId)"
        )
      ],
      planning: TaskBoardPlanningState(summary: "Cache external items"),
      workflow: nil,
      sessionId: nil,
      workItemId: nil,
      usage: TaskBoardUsage(),
      createdAt: "2026-05-19T10:00:00Z",
      updatedAt: "2026-05-19T10:05:00Z",
      deletedAt: nil
    )
  }

  private func makeTaskBoardOrchestratorStatus() -> TaskBoardOrchestratorStatus {
    TaskBoardOrchestratorStatus(
      enabled: true,
      running: false,
      workflowExecutionCounts: [TaskBoardWorkflowExecutionCount(status: .completed, count: 2)],
      settings: TaskBoardOrchestratorSettings(
        enabledWorkflows: [.defaultTask],
        dryRunDefault: false,
        dispatchStatusFilter: .todo,
        policyVersion: "2026-05-19"
      )
    )
  }

  private func makeV1Container(at url: URL) throws -> ModelContainer {
    let schema = Schema(versionedSchema: HarnessMonitorSchemaV1.self)
    let config = ModelConfiguration("HarnessMonitorStore", schema: schema, url: url)
    return try ModelContainer(for: schema, configurations: [config])
  }

  private func makeV6Container(at url: URL) throws -> ModelContainer {
    let schema = Schema(versionedSchema: HarnessMonitorSchemaV6.self)
    let config = ModelConfiguration("HarnessMonitorStore", schema: schema, url: url)
    return try ModelContainer(for: schema, configurations: [config])
  }

  private func makeV11Container(at url: URL) throws -> ModelContainer {
    let schema = Schema(versionedSchema: HarnessMonitorSchemaV11.self)
    let config = ModelConfiguration("HarnessMonitorStore", schema: schema, url: url)
    return try ModelContainer(for: schema, configurations: [config])
  }

  private func makeUnknownVersionContainer(at url: URL) throws -> ModelContainer {
    let schema = Schema(versionedSchema: HarnessMonitorUnknownModelVersionSchema.self)
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

  private func seedV6Store(
    at url: URL,
    metricsData: Data
  ) throws {
    let container = try makeV6Container(at: url)
    let project = HarnessMonitorSchemaV6.CachedProject(
      projectId: "proj-v6",
      name: "Harness",
      projectDir: "/tmp/harness",
      contextRoot: "/tmp/harness-context",
      activeSessionCount: 1,
      totalSessionCount: 1
    )
    let session = HarnessMonitorSchemaV6.CachedSession(
      sessionId: "sess-v6",
      projectId: "proj-v6",
      projectName: "Harness",
      projectDir: "/tmp/harness",
      contextRoot: "/tmp/harness-context",
      worktreePath: "/tmp/harness/.worktrees/fix",
      sharedPath: "/tmp/harness-shared",
      originPath: "/tmp/harness-origin",
      branchRef: "fix/review-findings",
      title: "Migrated V6 session",
      context: "Migrated V6 context",
      statusRaw: SessionStatus.active.rawValue,
      createdAt: "2026-04-03T12:00:00Z",
      updatedAt: "2026-04-03T12:05:00Z",
      lastActivityAt: "2026-04-03T12:05:00Z",
      leaderId: "leader-v6",
      observeId: "observe-v6",
      metricsData: metricsData
    )

    container.mainContext.insert(project)
    container.mainContext.insert(session)
    try container.mainContext.save()
  }

  private func seedUnknownVersionStore(at url: URL) throws {
    let container = try makeUnknownVersionContainer(at: url)
    container.mainContext.insert(UnknownCacheRecord(id: "unknown-version-record"))
    try container.mainContext.save()
  }

  private func seedV11TranscriptStore(at url: URL) throws {
    let container = try makeV11TranscriptStoreContainer(at: url)
    let transcript = HarnessMonitorSchemaV11.CachedSessionTranscriptEntry(
      sessionId: "sess-v11",
      entryId: "entry-v11",
      recordedAt: "2026-04-03T12:05:00Z",
      kind: "assistant_message",
      agentId: "agent-v11",
      taskId: nil,
      summary: "Cached transcript row",
      payloadData: Data("{}".utf8)
    )

    container.mainContext.insert(transcript)
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

  @Test("Live SwiftData store reopens persisted task-board snapshots across store recreation")
  func liveStoreReopensPersistedTaskBoardSnapshotsAcrossStoreRecreation() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let environment = HarnessMonitorEnvironment(
      values: ["XDG_DATA_HOME": root.path],
      homeDirectory: root
    )
    let githubItem = makeTaskBoardItem(
      id: "board-live-github",
      provider: .gitHub,
      externalId: "321"
    )
    let todoistItem = makeTaskBoardItem(
      id: "board-live-todoist",
      provider: .todoist,
      externalId: "654"
    )
    let orchestratorStatus = makeTaskBoardOrchestratorStatus()

    do {
      let firstContainer = try HarnessMonitorModelContainer.live(using: environment)
      let firstStore = HarnessMonitorStore(
        daemonController: RecordingDaemonController(),
        modelContainer: firstContainer
      )
      await firstStore.cacheTaskBoardSnapshot(
        items: [githubItem, todoistItem],
        orchestratorStatus: orchestratorStatus
      )
    }

    let reopenedContainer = try HarnessMonitorModelContainer.live(using: environment)
    let reopenedStore = HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      modelContainer: reopenedContainer
    )

    let cached = await reopenedStore.loadCachedTaskBoardSnapshot()

    #expect(cached?.items.map(\.id) == ["board-live-github", "board-live-todoist"])
    #expect(cached?.items.map(\.externalRefs.first?.provider) == [.gitHub, .todoist])
    #expect(cached?.orchestratorStatus == orchestratorStatus)
    #expect(cached?.cachedAt != nil)
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

  @Test("Live SwiftData store migrates V6 cache records into V7 supervisor schema")
  func liveStoreMigratesV6CacheRecordsIntoSupervisorSchema() throws {
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
    try seedV6Store(at: storeURL, metricsData: metricsData)

    let container = try HarnessMonitorModelContainer.live(using: environment)
    let projects = try container.mainContext.fetch(FetchDescriptor<CachedProject>())
    let sessions = try container.mainContext.fetch(FetchDescriptor<CachedSession>())
    let decisions = try container.mainContext.fetch(FetchDescriptor<Decision>())
    let events = try container.mainContext.fetch(FetchDescriptor<SupervisorEvent>())
    let configs = try container.mainContext.fetch(FetchDescriptor<PolicyConfigRow>())

    #expect(projects.count == 1)
    #expect(projects.first?.projectId == "proj-v6")
    #expect(sessions.count == 1)
    #expect(sessions.first?.sessionId == "sess-v6")
    #expect(sessions.first?.branchRef == "fix/review-findings")
    #expect(decisions.isEmpty)
    #expect(events.isEmpty)
    #expect(configs.isEmpty)
  }

}

// swiftlint:enable type_body_length

extension PersistenceOfflineDurabilityTests {
  @Test("Live SwiftData store rebuilds incompatible cache stores with unknown model versions")
  func liveStoreRebuildsIncompatibleCacheStoreWithUnknownModelVersion() throws {
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
    try seedUnknownVersionStore(at: storeURL)

    let container = try HarnessMonitorModelContainer.live(using: environment)
    let bookmarks = try container.mainContext.fetch(FetchDescriptor<SessionBookmark>())
    let quarantineRoot =
      harnessRoot
      .appendingPathComponent("incompatible-cache-stores", isDirectory: true)
    let quarantinedStores = try FileManager.default.contentsOfDirectory(
      at: quarantineRoot,
      includingPropertiesForKeys: nil
    )
    let quarantinedFiles = try FileManager.default.contentsOfDirectory(
      at: try #require(quarantinedStores.first),
      includingPropertiesForKeys: nil
    )
    .map(\.lastPathComponent)

    #expect(bookmarks.isEmpty)
    #expect(FileManager.default.fileExists(atPath: storeURL.path))
    #expect(quarantinedStores.count == 1)
    #expect(quarantinedFiles.contains("harness-cache.store"))
  }

  @Test("Live SwiftData store migrates V11 transcript cache rows without source provenance")
  func liveStoreMigratesV11TranscriptCacheRowsWithoutSourceProvenance() throws {
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
    try seedV11TranscriptStore(at: storeURL)

    let container = try HarnessMonitorModelContainer.live(using: environment)
    let transcriptRows = try container.mainContext.fetch(
      FetchDescriptor<CachedSessionTranscriptEntry>()
    )

    #expect(transcriptRows.count == 1)
    #expect(transcriptRows.first?.sessionId == "sess-v11")
    #expect(transcriptRows.first?.entryId == "entry-v11")
    #expect(transcriptRows.first?.sourceRaw == nil)
  }
}

@MainActor
final class PersistenceOfflineDurabilityXCTests: XCTestCase {
  func testLiveStoreMigratesV11TranscriptCacheRowsWithoutSourceProvenance() throws {
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
    try seedV11TranscriptStoreFixture(at: storeURL)

    let container = try HarnessMonitorModelContainer.live(using: environment)
    let transcriptRows = try container.mainContext.fetch(
      FetchDescriptor<CachedSessionTranscriptEntry>()
    )

    XCTAssertEqual(transcriptRows.count, 1)
    XCTAssertEqual(transcriptRows.first?.sessionId, "sess-v11")
    XCTAssertEqual(transcriptRows.first?.entryId, "entry-v11")
    XCTAssertNil(transcriptRows.first?.sourceRaw)
  }
}

@MainActor
private func makeV11TranscriptStoreContainer(at url: URL) throws -> ModelContainer {
  let schema = Schema(versionedSchema: HarnessMonitorSchemaV11.self)
  let config = ModelConfiguration("HarnessMonitorStore", schema: schema, url: url)
  return try ModelContainer(for: schema, configurations: [config])
}

@MainActor
private func seedV11TranscriptStoreFixture(at url: URL) throws {
  let container = try makeV11TranscriptStoreContainer(at: url)
  let transcript = HarnessMonitorSchemaV11.CachedSessionTranscriptEntry(
    sessionId: "sess-v11",
    entryId: "entry-v11",
    recordedAt: "2026-04-03T12:05:00Z",
    kind: "assistant_message",
    agentId: "agent-v11",
    taskId: nil,
    summary: "Cached transcript row",
    payloadData: Data("{}".utf8)
  )

  container.mainContext.insert(transcript)
  try container.mainContext.save()
}

private enum HarnessMonitorUnknownModelVersionSchema: VersionedSchema {
  static var versionIdentifier: Schema.Version { Schema.Version(999, 0, 0) }

  static var models: [any PersistentModel.Type] {
    [UnknownCacheRecord.self]
  }
}

@Model
private final class UnknownCacheRecord {
  var id: String

  init(id: String) {
    self.id = id
  }
}
