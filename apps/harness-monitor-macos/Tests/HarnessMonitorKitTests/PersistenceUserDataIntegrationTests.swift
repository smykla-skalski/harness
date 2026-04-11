import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Persistence user data integration")
struct PersistenceUserDataIntegrationTests {
  let harness: PersistenceIntegrationTestHarness

  init() throws {
    harness = try PersistenceIntegrationTestHarness()
  }

  @Test("Bookmark toggle persists and refreshes ID set")
  func bookmarkToggle() throws {
    let store = harness.makeStore()
    #expect(!store.isBookmarked(sessionId: "sess-bm"))

    store.toggleBookmark(sessionId: "sess-bm", projectId: "proj-1")
    #expect(store.isBookmarked(sessionId: "sess-bm"))

    store.toggleBookmark(sessionId: "sess-bm", projectId: "proj-1")
    #expect(!store.isBookmarked(sessionId: "sess-bm"))
  }

  @Test("User notes CRUD persists through fetch")
  func userNotesCRUD() throws {
    let store = harness.makeStore()

    #expect(
      store.addNote(
        text: "Fix this later",
        targetKind: "task",
        targetId: "task-42",
        sessionId: "sess-1"
      ))

    let notes = try harness.fetchNotes(targetId: "task-42", sessionId: "sess-1")
    #expect(notes.count == 1)
    #expect(notes.first?.text == "Fix this later")

    if let note = notes.first {
      #expect(store.deleteNote(note))
    }
    #expect(try harness.fetchNotes(targetId: "task-42", sessionId: "sess-1").isEmpty)
  }

  @Test("User notes stay scoped to their session")
  func userNotesStayScopedToSession() throws {
    let store = harness.makeStore()

    #expect(
      store.addNote(
        text: "Session one note",
        targetKind: "task",
        targetId: "task-42",
        sessionId: "sess-1"
      ))
    #expect(
      store.addNote(
        text: "Session two note",
        targetKind: "task",
        targetId: "task-42",
        sessionId: "sess-2"
      ))

    let sessionOneNotes = try harness.fetchNotes(targetId: "task-42", sessionId: "sess-1")
    let sessionTwoNotes = try harness.fetchNotes(targetId: "task-42", sessionId: "sess-2")

    #expect(sessionOneNotes.count == 1)
    #expect(sessionOneNotes.first?.text == "Session one note")
    #expect(sessionTwoNotes.count == 1)
    #expect(sessionTwoNotes.first?.text == "Session two note")
  }

  @Test("Recent search records and evicts")
  func recentSearchRecordsAndEvicts() throws {
    let store = harness.makeStore()

    store.recordSearch("cockpit")
    store.recordSearch("blocked")
    store.recordSearch("cockpit")

    let searches = try harness.fetchRecentSearches()
    #expect(searches.count == 2)
    #expect(searches.first?.query == "cockpit")
    #expect(searches.first?.useCount == 2)

    store.clearSearchHistory()
    #expect(try harness.fetchRecentSearches().isEmpty)
  }

  @Test("Mutation updates the cached session list summary")
  func mutationUpdatesCachedSessionListSummary() async throws {
    let client = RecordingHarnessClient()
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client),
      modelContainer: harness.container
    )
    let sessionID = PreviewFixtures.summary.sessionId

    await store.bootstrap()
    await store.selectSession(sessionID)

    let ended = await store.endSelectedSession()
    #expect(ended)

    try await Task.sleep(for: .milliseconds(50))
    let cached = await store.loadCachedSessionList()
    let summary = cached?.sessions.first { $0.sessionId == sessionID }
    #expect(summary?.status == .ended)
  }

  @Test("Filter preferences save and restore")
  func filterPreferencesSaveAndRestore() {
    let store = harness.makeStore()

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
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      persistenceError: "Local persistence is unavailable."
    )

    #expect(store.isPersistenceAvailable == false)
    #expect(store.selectedSessionBookmarkTitle == "Bookmarks Unavailable")
    #expect(store.toggleBookmark(sessionId: "sess-bm", projectId: "proj-1") == false)
    #expect(
      store.addNote(
        text: "Should not save",
        targetKind: "task",
        targetId: "task-42",
        sessionId: "sess-1"
      ) == false)
    #expect(store.recordSearch("cockpit") == false)
    #expect(store.clearSearchHistory() == false)
    #expect(store.isBookmarked(sessionId: "sess-bm") == false)
    #expect(store.currentFailureFeedbackMessage == "Local persistence is unavailable.")
  }
}
