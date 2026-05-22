import Foundation
import SwiftData
import Testing
import XCTest

@testable import HarnessMonitorKit

@MainActor
@Suite("Persistence offline durability")
struct PersistenceOfflineDurabilityTests {
  let previewContainer: ModelContainer

  init() throws {
    previewContainer = try HarnessMonitorModelContainer.preview()
  }

  func makeStore() -> HarnessMonitorStore {
    HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      modelContainer: previewContainer
    )
  }

  func fetchNotes(
    targetId: String,
    sessionId: String
  ) throws -> [UserNote] {
    let notes = try previewContainer.mainContext.fetch(FetchDescriptor<UserNote>())
    return
      notes
      .filter { $0.targetId == targetId && $0.sessionId == sessionId }
      .sorted { $0.createdAt > $1.createdAt }
  }

  func fetchRecentSearches() throws -> [RecentSearch] {
    try previewContainer.mainContext.fetch(
      FetchDescriptor<RecentSearch>(
        sortBy: [SortDescriptor(\RecentSearch.lastUsedAt, order: .reverse)]
      ))
  }

  func makeTaskBoardItem(
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

  func makeTaskBoardOrchestratorStatus() -> TaskBoardOrchestratorStatus {
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

  func makeV1Container(at url: URL) throws -> ModelContainer {
    let schema = Schema(versionedSchema: HarnessMonitorSchemaV1.self)
    let config = ModelConfiguration("HarnessMonitorStore", schema: schema, url: url)
    return try ModelContainer(for: schema, configurations: [config])
  }

  func makeV6Container(at url: URL) throws -> ModelContainer {
    let schema = Schema(versionedSchema: HarnessMonitorSchemaV6.self)
    let config = ModelConfiguration("HarnessMonitorStore", schema: schema, url: url)
    return try ModelContainer(for: schema, configurations: [config])
  }

  func makeV11Container(at url: URL) throws -> ModelContainer {
    let schema = Schema(versionedSchema: HarnessMonitorSchemaV11.self)
    let config = ModelConfiguration("HarnessMonitorStore", schema: schema, url: url)
    return try ModelContainer(for: schema, configurations: [config])
  }

  func makeUnknownVersionContainer(at url: URL) throws -> ModelContainer {
    let schema = Schema(versionedSchema: HarnessMonitorUnknownModelVersionSchema.self)
    let config = ModelConfiguration("HarnessMonitorStore", schema: schema, url: url)
    return try ModelContainer(for: schema, configurations: [config])
  }

  func seedV1Store(
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

  func seedV6Store(
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

  func seedUnknownVersionStore(at url: URL) throws {
    let container = try makeUnknownVersionContainer(at: url)
    container.mainContext.insert(UnknownCacheRecord(id: "unknown-version-record"))
    try container.mainContext.save()
  }

  func seedV11TranscriptStore(at url: URL) throws {
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

}
