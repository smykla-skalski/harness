import Foundation
import SwiftData
import Testing
import XCTest

@testable import HarnessMonitorKit

@MainActor
extension PersistenceOfflineDurabilityTests {
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
    #expect(migratedProject?.worktrees.isEmpty == true)

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
func makeV11TranscriptStoreContainer(at url: URL) throws -> ModelContainer {
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

enum HarnessMonitorUnknownModelVersionSchema: VersionedSchema {
  static var versionIdentifier: Schema.Version { Schema.Version(999, 0, 0) }

  static var models: [any PersistentModel.Type] {
    [UnknownCacheRecord.self]
  }
}

@Model
final class UnknownCacheRecord {
  var id: String

  init(id: String) {
    self.id = id
  }
}
