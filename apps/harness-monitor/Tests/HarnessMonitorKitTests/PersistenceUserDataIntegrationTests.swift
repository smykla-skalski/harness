import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Persistence user data integration", .serialized)
struct PersistenceUserDataIntegrationTests {
  let harness: PersistenceIntegrationTestHarness

  init() throws {
    harness = try PersistenceIntegrationTestHarness()
  }

  @Test("Bookmark toggle persists and refreshes ID set")
  func bookmarkToggle() async throws {
    let store = harness.makeStore()
    #expect(!store.isBookmarked(sessionId: "sess-bm"))

    await store.toggleBookmark(sessionId: "sess-bm", projectId: "proj-1")
    #expect(store.isBookmarked(sessionId: "sess-bm"))

    await store.toggleBookmark(sessionId: "sess-bm", projectId: "proj-1")
    #expect(!store.isBookmarked(sessionId: "sess-bm"))
  }

  @Test("User notes CRUD persists through fetch")
  func userNotesCRUD() async throws {
    let store = harness.makeStore()

    #expect(
      await store.addNote(
        text: "Fix this later",
        targetKind: "task",
        targetId: "task-42",
        sessionId: "sess-1"
      ))

    let notes = try harness.fetchNotes(targetId: "task-42", sessionId: "sess-1")
    #expect(notes.count == 1)
    #expect(notes.first?.text == "Fix this later")

    if let note = notes.first {
      #expect(await store.deleteNote(note))
    }
    #expect(try harness.fetchNotes(targetId: "task-42", sessionId: "sess-1").isEmpty)
  }

  @Test("User notes stay scoped to their session")
  func userNotesStayScopedToSession() async throws {
    let store = harness.makeStore()

    #expect(
      await store.addNote(
        text: "Session one note",
        targetKind: "task",
        targetId: "task-42",
        sessionId: "sess-1"
      ))
    #expect(
      await store.addNote(
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
  func recentSearchRecordsAndEvicts() async throws {
    let store = harness.makeStore()

    await store.recordSearch("cockpit")
    await store.recordSearch("blocked")
    await store.recordSearch("cockpit")

    let searches = try harness.fetchRecentSearches()
    #expect(searches.count == 2)
    #expect(searches.first?.query == "cockpit")
    #expect(searches.first?.useCount == 2)

    await store.clearSearchHistory()
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
    await store.waitForSessionIndexIdle()
    await store.flushPendingCacheWrite()

    let ended = await store.endSelectedSession()
    #expect(ended)

    await store.waitForSessionIndexIdle()
    await store.flushPendingCacheWrite()
    let cached = await store.loadCachedSessionList()
    let summary = cached?.sessions.first { $0.sessionId == sessionID }
    #expect(summary?.status == .ended)
  }

  @Test("Filter settings save and restore")
  func filterSettingsSaveAndRestore() async {
    let store = harness.makeStore()

    store.sessionFilter = .ended
    store.sessionFocusFilter = .blocked
    await store.saveFilterPreference(for: "proj-1")

    store.sessionFilter = .active
    store.sessionFocusFilter = .all

    await store.loadFilterPreference(for: "proj-1")
    #expect(store.sessionFilter == .ended)
    #expect(store.sessionFocusFilter == .blocked)
  }

  @Test("Notification history persists toast events")
  func notificationHistoryPersistsToastEvents() async throws {
    let store = harness.makeStore()

    store.presentSuccessFeedback("Notification history captured")

    for _ in 0..<20 {
      if !(try harness.fetchNotificationHistory()).isEmpty {
        break
      }
      await Task.yield()
    }

    let history = try harness.fetchNotificationHistory()
    #expect(history.count == 1)
    #expect(history.first?.source == .toast)
    #expect(history.first?.message == "Notification history captured")
    #expect(history.first?.status == .active)
  }

  @Test("Notification history drops runtime-only rows on relaunch refresh")
  func notificationHistoryDropsRuntimeOnlyRowsOnRefresh() async throws {
    let store = harness.makeStore()
    let feedback = ActionFeedback(
      title: "Task removed",
      message: "Undo is still available",
      severity: .undoable,
      details: nil,
      primaryAction: nil,
      accessibilityIdentifier: nil,
      issuedAt: ContinuousClock.now
    )

    await store.recordToastHistoryEvent(
      ToastHistoryEvent(
        feedback: feedback,
        recordedAt: .now,
        kind: .presented,
        hasUndoAction: true
      ))

    #expect(try harness.fetchNotificationHistory().count == 1)

    await store.refreshNotificationHistory()

    #expect(store.notificationHistoryEntries.isEmpty)
    #expect(try harness.fetchNotificationHistory().isEmpty)
  }

  @Test("Degraded persistence mode fails safely")
  func degradedPersistenceModeFailsSafely() async {
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      persistenceError: "Local persistence is unavailable."
    )

    #expect(store.isPersistenceAvailable == false)
    #expect(store.selectedSessionBookmarkTitle == "Bookmarks Unavailable")
    #expect(await store.toggleBookmark(sessionId: "sess-bm", projectId: "proj-1") == false)
    #expect(
      await store.addNote(
        text: "Should not save",
        targetKind: "task",
        targetId: "task-42",
        sessionId: "sess-1"
      ) == false)
    #expect(await store.recordSearch("cockpit") == false)
    #expect(await store.clearSearchHistory() == false)
    #expect(store.isBookmarked(sessionId: "sess-bm") == false)
    #expect(store.currentFailureFeedbackMessage == "Local persistence is unavailable")
  }
}
