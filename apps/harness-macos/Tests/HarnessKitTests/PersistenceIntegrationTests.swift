import SwiftData
import Testing

@testable import HarnessKit

@MainActor
@Suite("Persistence integration")
struct PersistenceIntegrationTests {
  let container: ModelContainer

  init() throws {
    container = try HarnessModelContainer.preview()
  }

  private func makeStore() -> HarnessStore {
    HarnessStore(
      daemonController: RecordingDaemonController(),
      modelContext: container.mainContext
    )
  }

  private func fetchNotes(
    targetId: String,
    sessionId: String
  ) throws -> [UserNote] {
    let notes = try container.mainContext.fetch(FetchDescriptor<UserNote>())
    return notes
      .filter { $0.targetId == targetId && $0.sessionId == sessionId }
      .sorted { $0.createdAt > $1.createdAt }
  }

  @Test("cacheSessionList writes projects and sessions")
  func cacheSessionListWritesThenReads() throws {
    let store = makeStore()
    let project = makeProject(totalSessionCount: 1, activeSessionCount: 1)
    let session = makeSession(.init(
      sessionId: "sess-1",
      context: "Test session",
      status: .active,
      openTaskCount: 0,
      inProgressTaskCount: 0,
      blockedTaskCount: 0,
      activeAgentCount: 1
    ))

    store.cacheSessionList([session], projects: [project])

    let cached = store.loadCachedSessionList()
    #expect(cached != nil)
    #expect(cached?.sessions.count == 1)
    #expect(cached?.sessions.first?.sessionId == "sess-1")
    #expect(cached?.projects.count == 1)
    #expect(cached?.projects.first?.projectId == project.projectId)
  }

  @Test("cacheSessionDetail stores full detail and timeline")
  func cacheSessionDetailWritesThenReads() throws {
    let store = makeStore()
    let session = makeSession(.init(
      sessionId: "sess-detail",
      context: "Detail test",
      status: .active,
      leaderId: "leader-1",
      openTaskCount: 0,
      inProgressTaskCount: 0,
      blockedTaskCount: 0,
      activeAgentCount: 2
    ))

    let detail = makeSessionDetail(
      summary: session,
      workerID: "worker-1",
      workerName: "Codex Worker"
    )
    let timeline = makeTimelineEntries(
      sessionID: "sess-detail",
      agentID: "leader-1",
      summary: "Test checkpoint"
    )

    store.cacheSessionDetail(detail, timeline: timeline)

    let cached = store.loadCachedSessionDetail(sessionID: "sess-detail")
    #expect(cached != nil)
    #expect(cached?.detail.session.sessionId == "sess-detail")
    #expect(cached?.detail.agents.count == 2)
    #expect(cached?.timeline.count == 1)
    #expect(cached?.timeline.first?.summary == "Test checkpoint")
  }

  @Test("cacheSessionDetail updates existing session in place")
  func cacheSessionDetailUpdatesInPlace() throws {
    let store = makeStore()
    let session = makeSession(.init(
      sessionId: "sess-update",
      context: "Original",
      status: .active,
      openTaskCount: 0,
      inProgressTaskCount: 0,
      blockedTaskCount: 0,
      activeAgentCount: 1
    ))

    let detail = makeSessionDetail(
      summary: session,
      workerID: "w-1",
      workerName: "Worker"
    )
    store.cacheSessionDetail(detail, timeline: [])

    let updated = makeSession(.init(
      sessionId: "sess-update",
      context: "Updated",
      status: .active,
      openTaskCount: 3,
      inProgressTaskCount: 1,
      blockedTaskCount: 0,
      activeAgentCount: 2
    ))
    let updatedDetail = makeSessionDetail(
      summary: updated,
      workerID: "w-2",
      workerName: "New Worker"
    )
    store.cacheSessionDetail(updatedDetail, timeline: [])

    let descriptor = FetchDescriptor<CachedSession>()
    let all = try container.mainContext.fetch(descriptor)
    #expect(all.count == 1)

    let cached = store.loadCachedSessionDetail(sessionID: "sess-update")
    #expect(cached?.detail.session.context == "Updated")
    #expect(cached?.detail.agents.count == 2)
  }

  @Test("Eviction keeps only 50 most recently viewed sessions")
  func evictionRemovesOldSessions() throws {
    let store = makeStore()

    for index in 0..<55 {
      let session = makeSession(.init(
        sessionId: "sess-\(index)",
        context: "Session \(index)",
        status: .active,
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 0
      ))
      let detail = SessionDetail(
        session: session,
        agents: [],
        tasks: [],
        signals: [],
        observer: nil,
        agentActivity: []
      )
      store.cacheSessionDetail(detail, timeline: [])
    }

    let descriptor = FetchDescriptor<CachedSession>()
    let remaining = try container.mainContext.fetch(descriptor)
    #expect(remaining.count <= 50)
  }

  @Test("loadCachedSessionList returns nil on empty store")
  func loadCachedSessionListReturnsNilWhenEmpty() {
    let store = makeStore()
    #expect(store.loadCachedSessionList() == nil)
  }

  @Test("loadCachedSessionDetail returns nil for unviewed session")
  func loadCachedDetailReturnsNilForUnviewed() {
    let store = makeStore()
    let session = makeSession(.init(
      sessionId: "never-viewed",
      context: "Never viewed",
      status: .active,
      openTaskCount: 0,
      inProgressTaskCount: 0,
      blockedTaskCount: 0,
      activeAgentCount: 0
    ))
    store.cacheSessionList([session], projects: [])

    #expect(store.loadCachedSessionDetail(sessionID: "never-viewed") == nil)
  }

  @Test("Bookmark toggle persists and refreshes ID set")
  func bookmarkToggle() throws {
    let store = makeStore()
    #expect(!store.isBookmarked(sessionId: "sess-bm"))

    store.toggleBookmark(sessionId: "sess-bm", projectId: "proj-1")
    #expect(store.isBookmarked(sessionId: "sess-bm"))

    store.toggleBookmark(sessionId: "sess-bm", projectId: "proj-1")
    #expect(!store.isBookmarked(sessionId: "sess-bm"))
  }

  @Test("User notes CRUD persists through fetch")
  func userNotesCRUD() throws {
    let store = makeStore()

    #expect(store.addNote(
      text: "Fix this later",
      targetKind: "task",
      targetId: "task-42",
      sessionId: "sess-1"
    ))

    let notes = try fetchNotes(targetId: "task-42", sessionId: "sess-1")
    #expect(notes.count == 1)
    #expect(notes.first?.text == "Fix this later")

    if let note = notes.first {
      #expect(store.deleteNote(note))
    }
    #expect(try fetchNotes(targetId: "task-42", sessionId: "sess-1").isEmpty)
  }

  @Test("User notes stay scoped to their session")
  func userNotesStayScopedToSession() throws {
    let store = makeStore()

    #expect(store.addNote(
      text: "Session one note",
      targetKind: "task",
      targetId: "task-42",
      sessionId: "sess-1"
    ))
    #expect(store.addNote(
      text: "Session two note",
      targetKind: "task",
      targetId: "task-42",
      sessionId: "sess-2"
    ))

    let sessionOneNotes = try fetchNotes(targetId: "task-42", sessionId: "sess-1")
    let sessionTwoNotes = try fetchNotes(targetId: "task-42", sessionId: "sess-2")

    #expect(sessionOneNotes.count == 1)
    #expect(sessionOneNotes.first?.text == "Session one note")
    #expect(sessionTwoNotes.count == 1)
    #expect(sessionTwoNotes.first?.text == "Session two note")
  }

  @Test("Recent search records and evicts")
  func recentSearchRecordsAndEvicts() throws {
    let store = makeStore()

    store.recordSearch("cockpit")
    store.recordSearch("blocked")
    store.recordSearch("cockpit")

    let searches = store.recentSearches
    #expect(searches.count == 2)
    #expect(searches.first?.query == "cockpit")
    #expect(searches.first?.useCount == 2)

    store.clearSearchHistory()
    #expect(store.recentSearches.isEmpty)
  }

  @Test("Filter preferences save and restore")
  func filterPreferencesSaveAndRestore() {
    let store = makeStore()

    store.sessionFilter = .ended
    store.sessionFocusFilter = .blocked
    store.saveFilterPreference(for: "proj-1")

    store.sessionFilter = .active
    store.sessionFocusFilter = .all

    store.loadFilterPreference(for: "proj-1")
    #expect(store.sessionFilter == .ended)
    #expect(store.sessionFocusFilter == .blocked)
  }

  @Test("Degraded persistence mode fails safely")
  func degradedPersistenceModeFailsSafely() {
    let store = HarnessStore(
      daemonController: RecordingDaemonController(),
      persistenceError: "Local persistence is unavailable."
    )

    #expect(store.isPersistenceAvailable == false)
    #expect(store.selectedSessionBookmarkTitle == "Bookmarks Unavailable")
    #expect(store.toggleBookmark(sessionId: "sess-bm", projectId: "proj-1") == false)
    #expect(store.addNote(
      text: "Should not save",
      targetKind: "task",
      targetId: "task-42",
      sessionId: "sess-1"
    ) == false)
    #expect(store.recordSearch("cockpit") == false)
    #expect(store.clearSearchHistory() == false)
    #expect(store.recentSearches.isEmpty)
    #expect(store.isBookmarked(sessionId: "sess-bm") == false)
    #expect(store.lastError == "Local persistence is unavailable.")
  }
}
