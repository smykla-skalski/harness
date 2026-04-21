import Foundation
import Testing

@testable import HarnessMonitorKit

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

  @Test("Requesting external session attach increments the importer request")
  func requestAttachExternalSessionIncrementsImporterRequest() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())

    store.requestAttachExternalSession()

    #expect(store.attachSessionRequest == 1)
  }
}
