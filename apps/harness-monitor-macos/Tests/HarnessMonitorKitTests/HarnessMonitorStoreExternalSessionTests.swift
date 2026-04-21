import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("Harness Monitor store external sessions")
struct HarnessMonitorStoreExternalSessionTests {
  @Test("Adopting an external session selects the adopted session and dismisses the sheet")
  func adoptExternalSessionSelectsAdoptedSession() async throws {
    let adoptedSummary = makeSession(
      .init(
        sessionId: "sess-adopted",
        context: "Imported attach lane",
        status: .active,
        leaderId: "leader-adopted",
        observeId: "observe-adopted",
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 2
      )
    )
    let adoptedDetail = makeSessionDetail(
      summary: adoptedSummary,
      workerID: "worker-adopted",
      workerName: "Worker Adopted"
    )
    let client = RecordingHarnessClient(detail: adoptedDetail)
    client.configureSessions(
      summaries: [PreviewFixtures.summary],
      detailsByID: [PreviewFixtures.summary.sessionId: PreviewFixtures.detail]
    )
    let store = await makeBootstrappedStore(client: client)
    let preview = SessionDiscoveryProbe.Preview(
      sessionId: adoptedSummary.sessionId,
      projectName: adoptedSummary.projectName,
      title: adoptedSummary.title,
      createdAt: Date(timeIntervalSince1970: 0),
      originPath: adoptedSummary.originPath,
      originReachable: true,
      sessionRoot: URL(fileURLWithPath: "/tmp/sess-adopted")
    )

    store.presentedSheet = .attachExternal(bookmarkId: "B-adopt", preview: preview)
    await store.adoptExternalSession(bookmarkID: "B-adopt", preview: preview)

    #expect(store.presentedSheet == nil)
    #expect(store.selectedSessionID == adoptedSummary.sessionId)
    #expect(store.selectedSession?.session.sessionId == adoptedSummary.sessionId)
    #expect(
      client.recordedCalls().contains(
        .adoptSession(bookmarkID: "B-adopt", sessionRoot: preview.sessionRoot)
      )
    )
    #expect(client.readCallCount(.sessionDetail(adoptedSummary.sessionId)) == 1)
  }

  @Test("Diagnostics snapshot tracks attached external session count and last successful attach")
  func diagnosticsSnapshotTracksSuccessfulAttach() async throws {
    let adoptedSummary = SessionSummary(
      projectId: "project-a",
      projectName: "demo",
      projectDir: "/Users/example/Projects/demo",
      contextRoot: "/Users/example/Library/Application Support/harness/projects/project-a",
      sessionId: "sess-external",
      worktreePath: "/tmp/sess-external/workspace",
      sharedPath: "/tmp/sess-external/memory",
      originPath: "/Users/example/Projects/demo",
      branchRef: "harness/sess-external",
      title: "External Session",
      context: "Imported attach lane",
      status: .active,
      createdAt: "2026-04-20T12:00:00Z",
      updatedAt: "2026-04-20T12:00:00Z",
      lastActivityAt: "2026-04-20T12:00:00Z",
      leaderId: "leader-external",
      observeId: "observe-external",
      pendingLeaderTransfer: nil,
      externalOrigin: "/tmp/sess-external",
      adoptedAt: "2026-04-20T12:00:00Z",
      metrics: SessionMetrics(
        agentCount: 2,
        activeAgentCount: 2,
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        completedTaskCount: 0
      )
    )
    let adoptedDetail = makeSessionDetail(
      summary: adoptedSummary,
      workerID: "worker-external",
      workerName: "Worker External"
    )
    let client = RecordingHarnessClient(detail: adoptedDetail)
    client.configureSessions(
      summaries: [PreviewFixtures.summary],
      detailsByID: [PreviewFixtures.summary.sessionId: PreviewFixtures.detail]
    )
    let store = await makeBootstrappedStore(client: client)
    let preview = SessionDiscoveryProbe.Preview(
      sessionId: adoptedSummary.sessionId,
      projectName: adoptedSummary.projectName,
      title: adoptedSummary.title,
      createdAt: Date(timeIntervalSince1970: 0),
      originPath: adoptedSummary.originPath,
      originReachable: true,
      sessionRoot: URL(fileURLWithPath: "/tmp/sess-external")
    )

    await store.adoptExternalSession(bookmarkID: "B-external", preview: preview)

    let snapshot = PreferencesDiagnosticsSnapshot(store: store)
    #expect(intField(named: "externalSessionCount", in: snapshot) == 1)
    #expect(
      stringField(named: "lastExternalSessionAttachOutcome", in: snapshot)
        == "Attached session sess-external."
    )
    #expect(boolField(named: "lastExternalSessionAttachSucceeded", in: snapshot) == true)
  }

  @Test("Diagnostics snapshot tracks the last failed attach attempt")
  func diagnosticsSnapshotTracksFailedAttachAttempt() async throws {
    let store = await makeBootstrappedStore()

    await store.handleAttachSessionPicker(
      .failure(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    )

    let snapshot = PreferencesDiagnosticsSnapshot(store: store)
    #expect(intField(named: "externalSessionCount", in: snapshot) == 0)
    #expect(
      stringField(named: "lastExternalSessionAttachOutcome", in: snapshot)?
        .contains("Could not open session folder:") == true
    )
    #expect(boolField(named: "lastExternalSessionAttachSucceeded", in: snapshot) == false)
  }

  @Test("Importing an external session folder presents the attach sheet")
  func handleImportedExternalSessionFolderPresentsAttachSheet() async throws {
    let store = await makeBootstrappedStore()
    let fixture = try SessionProbeFixture.makeValid()

    await store.handleAttachSessionPicker(.success([fixture.url]))

    guard case .attachExternal(let bookmarkID, let preview?) = store.presentedSheet else {
      Issue.record("expected attach sheet with preview")
      return
    }

    #expect(!bookmarkID.isEmpty)
    #expect(preview.sessionId == "abc12345")
    #expect(preview.projectName == "demo")
    #expect(preview.sessionRoot == fixture.url)

    if let bookmarkStore = store.bookmarkStore {
      try await bookmarkStore.remove(id: bookmarkID)
    }
  }

  @Test("Importing an external session ignores a poisoned shared temp bookmark file")
  func handleImportedExternalSessionFolderIgnoresPoisonedSharedTempBookmarkFile() async throws {
    let sharedBookmarksURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("sandbox", isDirectory: true)
      .appendingPathComponent("bookmarks.json")
    try FileManager.default.createDirectory(
      at: sharedBookmarksURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(#"{"schemaVersion": 99, "bookmarks": []}"#.utf8).write(to: sharedBookmarksURL)

    let store = await makeBootstrappedStore()
    let fixture = try SessionProbeFixture.makeValid()

    await store.handleAttachSessionPicker(.success([fixture.url]))

    guard case .attachExternal(let bookmarkID, let preview?) = store.presentedSheet else {
      Issue.record("expected attach sheet with preview")
      return
    }

    #expect(!bookmarkID.isEmpty)
    #expect(preview.sessionId == "abc12345")
    #expect(preview.sessionRoot == fixture.url)

    if let bookmarkStore = store.bookmarkStore {
      try await bookmarkStore.remove(id: bookmarkID)
    }
  }

  @Test("Bootstrapped stores isolate bookmark persistence during tests")
  func bootstrappedStoresIsolateBookmarkPersistence() async throws {
    let first = await makeBootstrappedStore()
    let second = await makeBootstrappedStore()

    guard let firstBookmarks = first.bookmarkStore,
      let secondBookmarks = second.bookmarkStore
    else {
      Issue.record("expected bookmark stores")
      return
    }

    let record = try await firstBookmarks.add(
      url: FileManager.default.temporaryDirectory,
      kind: .projectRoot
    )

    #expect(await secondBookmarks.all().isEmpty)

    try await firstBookmarks.remove(id: record.id)
  }

  @Test("Requesting external session attach increments the importer request")
  func requestAttachExternalSessionIncrementsImporterRequest() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())

    store.requestAttachExternalSession()

    #expect(store.attachSessionRequest == 1)
  }
}

private func intField<T>(named name: String, in value: T) -> Int? {
  Mirror(reflecting: value).children.first { $0.label == name }?.value as? Int
}

private func stringField<T>(named name: String, in value: T) -> String? {
  Mirror(reflecting: value).children.first { $0.label == name }?.value as? String
}

private func boolField<T>(named name: String, in value: T) -> Bool? {
  Mirror(reflecting: value).children.first { $0.label == name }?.value as? Bool
}
