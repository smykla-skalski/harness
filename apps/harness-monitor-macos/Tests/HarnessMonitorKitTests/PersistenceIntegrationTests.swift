import Foundation
import SwiftData
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Persistence integration")
struct PersistenceIntegrationTests {
  let container: ModelContainer

  init() throws {
    container = try HarnessMonitorModelContainer.preview()
  }

  private func makeStore() -> HarnessMonitorStore {
    HarnessMonitorStore(
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

  private func fetchRecentSearches() throws -> [RecentSearch] {
    try container.mainContext.fetch(FetchDescriptor<RecentSearch>(
      sortBy: [SortDescriptor(\RecentSearch.lastUsedAt, order: .reverse)]
    ))
  }

  private struct LargeSnapshotFixture {
    let projects: [ProjectSummary]
    let sessions: [SessionSummary]
    let detailsByID: [String: SessionDetail]
  }

  private func largeSnapshotFixture(
    projectCount: Int = 6,
    sessionsPerProject: Int = 12
  ) -> LargeSnapshotFixture {
    var projects: [ProjectSummary] = []
    var sessions: [SessionSummary] = []
    var detailsByID: [String: SessionDetail] = [:]

    for projectIndex in 0..<projectCount {
      let projectId = "project-\(projectIndex)"
      let projectName = "Harness \(projectIndex)"
      let projectDir = "/Users/example/Projects/harness-\(projectIndex)"
      let contextRoot =
        "/Users/example/Library/Application Support/harness/projects/\(projectId)"

      projects.append(
        ProjectSummary(
          projectId: projectId,
          name: projectName,
          projectDir: projectDir,
          contextRoot: contextRoot,
          activeSessionCount: sessionsPerProject,
          totalSessionCount: sessionsPerProject
        )
      )

      for sessionIndex in 0..<sessionsPerProject {
        let token = projectIndex * sessionsPerProject + sessionIndex
        let recordedAt = String(
          format: "2026-04-%02dT14:%02d:%02dZ",
          1 + (token % 27),
          (token * 3) % 60,
          (token * 7) % 60
        )
        let session = SessionSummary(
          projectId: projectId,
          projectName: projectName,
          projectDir: projectDir,
          contextRoot: contextRoot,
          checkoutId: "checkout-\(projectIndex)",
          checkoutRoot: projectDir,
          isWorktree: false,
          worktreeName: nil,
          sessionId: "session-\(projectIndex)-\(sessionIndex)",
          context: "Regression lane \(projectIndex)-\(sessionIndex)",
          status: token.isMultiple(of: 5) ? .ended : .active,
          createdAt: recordedAt,
          updatedAt: recordedAt,
          lastActivityAt: recordedAt,
          leaderId: "leader-\(projectIndex)-\(sessionIndex)",
          observeId: token.isMultiple(of: 3) ? "observe-\(projectIndex)-\(sessionIndex)" : nil,
          pendingLeaderTransfer: nil,
          metrics: SessionMetrics(
            agentCount: 3,
            activeAgentCount: token.isMultiple(of: 5) ? 0 : 2,
            openTaskCount: token % 4,
            inProgressTaskCount: token % 3,
            blockedTaskCount: token % 2,
            completedTaskCount: token % 5
          )
        )
        sessions.append(session)
        detailsByID[session.sessionId] = makeSessionDetail(
          summary: session,
          workerID: "worker-\(projectIndex)-\(sessionIndex)",
          workerName: "Worker \(projectIndex)-\(sessionIndex)"
        )
      }
    }

    return LargeSnapshotFixture(
      projects: projects,
      sessions: sessions,
      detailsByID: detailsByID
    )
  }

  private func medianRuntimeMs(
    iterations: Int = 7,
    warmups: Int = 2,
    operation: @escaping () async throws -> Void
  ) async rethrows -> Double {
    for _ in 0..<warmups {
      try await operation()
    }

    var samples: [Double] = []
    samples.reserveCapacity(iterations)

    for _ in 0..<iterations {
      let startedAt = ContinuousClock.now
      try await operation()
      let duration = startedAt.duration(to: ContinuousClock.now)
      samples.append(durationMs(duration))
    }

    return samples.sorted()[samples.count / 2]
  }

  private func durationMs(_ duration: Duration) -> Double {
    let seconds = Double(duration.components.seconds) * 1_000
    let attoseconds = Double(duration.components.attoseconds) / 1_000_000_000_000_000
    return seconds + attoseconds
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

  @Test("Persistence keeps all cached sessions instead of evicting older snapshots")
  func persistenceKeepsAllCachedSessions() throws {
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
    #expect(remaining.count == 55)
  }

  @Test("loadCachedSessionList returns nil on empty store")
  func loadCachedSessionListReturnsNilWhenEmpty() {
    let store = makeStore()
    #expect(store.loadCachedSessionList() == nil)
  }

  @Test("Persisted detail stays loadable even when it was hydrated without manual viewing")
  func loadCachedDetailReturnsHydratedSnapshotWithoutManualViewing() {
    let store = makeStore()
    let session = makeSession(.init(
      sessionId: "hydrated-offline",
      context: "Hydrated offline",
      status: .active,
      leaderId: "leader-offline",
      openTaskCount: 0,
      inProgressTaskCount: 0,
      blockedTaskCount: 0,
      activeAgentCount: 1
    ))
    let detail = makeSessionDetail(
      summary: session,
      workerID: "worker-offline",
      workerName: "Offline Worker"
    )

    store.cacheSessionDetail(detail, timeline: [], markViewed: false)

    let cached = store.loadCachedSessionDetail(sessionID: "hydrated-offline")
    #expect(cached?.detail.session.sessionId == "hydrated-offline")
    #expect(store.persistedSessionCount == 1)
    #expect(store.lastPersistedSnapshotAt != nil)
  }

  @Test("Selecting a persisted session offline restores cached detail and timeline")
  func selectingPersistedSessionOfflineRestoresCachedSnapshot() async {
    let store = makeStore()
    let project = makeProject(totalSessionCount: 1, activeSessionCount: 1)
    let session = makeSession(.init(
      sessionId: "sess-offline-select",
      context: "Offline selection",
      status: .active,
      leaderId: "leader-offline-select",
      openTaskCount: 1,
      inProgressTaskCount: 0,
      blockedTaskCount: 0,
      activeAgentCount: 1
    ))
    let detail = makeSessionDetail(
      summary: session,
      workerID: "worker-select",
      workerName: "Offline Select Worker"
    )
    let timeline = makeTimelineEntries(
      sessionID: session.sessionId,
      agentID: detail.agents[0].agentId,
      summary: "Offline timeline snapshot"
    )

    store.cacheSessionList([session], projects: [project])
    store.cacheSessionDetail(detail, timeline: timeline, markViewed: false)
    store.connectionState = .offline("daemon down")

    await store.selectSession(session.sessionId)

    #expect(store.selectedSessionID == session.sessionId)
    #expect(store.selectedSession?.session.sessionId == session.sessionId)
    #expect(store.timeline == timeline)
    #expect(store.isShowingCachedData)
    #expect(store.sessionDataAvailability != .live)
  }

  @Test("Hydration helper detects when a persisted detail snapshot is missing")
  func persistedSnapshotNeedsHydrationReflectsSnapshotState() {
    let store = makeStore()
    let project = makeProject(totalSessionCount: 1, activeSessionCount: 1)
    let session = makeSession(.init(
      sessionId: "sess-hydration",
      context: "Hydration needed",
      status: .active,
      leaderId: "leader-hydration",
      openTaskCount: 0,
      inProgressTaskCount: 0,
      blockedTaskCount: 0,
      activeAgentCount: 1
    ))
    let detail = makeSessionDetail(
      summary: session,
      workerID: "worker-hydration",
      workerName: "Hydration Worker"
    )

    store.cacheSessionList([session], projects: [project])
    #expect(store.persistedSnapshotNeedsHydration(for: session))

    store.cacheSessionDetail(detail, timeline: [], markViewed: false)
    #expect(store.persistedSnapshotNeedsHydration(for: session) == false)
  }

  @Test("Performance budget: caching a 72-session snapshot stays under 90 ms median")
  func cacheSessionListStaysWithinPerformanceBudget() async throws {
    let fixture = largeSnapshotFixture()
    let medianMs = try await medianRuntimeMs {
      let container = try HarnessMonitorModelContainer.preview()
      let store = HarnessMonitorStore(
        daemonController: RecordingDaemonController(),
        modelContext: container.mainContext
      )
      store.cacheSessionList(fixture.sessions, projects: fixture.projects)
      let cached = store.loadCachedSessionList()
      #expect(cached?.sessions.count == fixture.sessions.count)
      #expect(cached?.projects.count == fixture.projects.count)
    }

    #expect(medianMs <= 90)
  }

  @Test("Performance budget: session-summary persistence fan-out stays under 45 ms median")
  func sessionSummaryUpdateStaysWithinPerformanceBudget() async throws {
    let fixture = largeSnapshotFixture()
    let container = try HarnessMonitorModelContainer.preview()
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      modelContext: container.mainContext
    )
    store.applySessionIndexSnapshot(
      projects: fixture.projects,
      sessions: fixture.sessions
    )
    store.cacheSessionList(fixture.sessions, projects: fixture.projects)

    var iteration = 0
    let medianMs = await medianRuntimeMs {
      let baseline = fixture.sessions[0]
      iteration += 1
      let updated = SessionSummary(
        projectId: baseline.projectId,
        projectName: baseline.projectName,
        projectDir: baseline.projectDir,
        contextRoot: baseline.contextRoot,
        checkoutId: baseline.checkoutId,
        checkoutRoot: baseline.checkoutRoot,
        isWorktree: baseline.isWorktree,
        worktreeName: baseline.worktreeName,
        sessionId: baseline.sessionId,
        context: "Regression lane 0-0 iteration \(iteration)",
        status: iteration.isMultiple(of: 2) ? .ended : .active,
        createdAt: baseline.createdAt,
        updatedAt: String(format: "2026-04-28T14:%02d:00Z", iteration % 60),
        lastActivityAt: String(format: "2026-04-28T14:%02d:00Z", iteration % 60),
        leaderId: baseline.leaderId,
        observeId: baseline.observeId,
        pendingLeaderTransfer: baseline.pendingLeaderTransfer,
        metrics: SessionMetrics(
          agentCount: baseline.metrics.agentCount,
          activeAgentCount: iteration.isMultiple(of: 2) ? 0 : baseline.metrics.activeAgentCount,
          openTaskCount: iteration % 5,
          inProgressTaskCount: iteration % 4,
          blockedTaskCount: iteration % 3,
          completedTaskCount: baseline.metrics.completedTaskCount + iteration
        )
      )
      store.applySessionSummaryUpdate(updated)
      let cached = store.loadCachedSessionList()
      let summary = cached?.sessions.first { $0.sessionId == updated.sessionId }
      #expect(summary?.updatedAt == updated.updatedAt)
    }

    #expect(medianMs <= 45)
  }

  @Test("Performance budget: refreshing a 72-session live snapshot stays under 160 ms median")
  func refreshLargeSnapshotStaysWithinPerformanceBudget() async throws {
    let fixture = largeSnapshotFixture()
    let medianMs = try await medianRuntimeMs {
      let container = try HarnessMonitorModelContainer.preview()
      let client = RecordingHarnessClient()
      client.configureSessions(
        summaries: fixture.sessions,
        detailsByID: fixture.detailsByID
      )
      let store = HarnessMonitorStore(
        daemonController: RecordingDaemonController(client: client),
        modelContext: container.mainContext
      )
      store.connectionState = .online
      await store.refresh(using: client, preserveSelection: true)
      store.sessionSnapshotHydrationTask?.cancel()
      store.sessionSnapshotHydrationTask = nil
      #expect(store.sessions.count == fixture.sessions.count)
      #expect(store.projects.count == fixture.projects.count)
    }

    #expect(medianMs <= 160)
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

    let searches = try fetchRecentSearches()
    #expect(searches.count == 2)
    #expect(searches.first?.query == "cockpit")
    #expect(searches.first?.useCount == 2)

    store.clearSearchHistory()
    #expect(try fetchRecentSearches().isEmpty)
  }

  @Test("Mutation updates the cached session list summary")
  func mutationUpdatesCachedSessionListSummary() async throws {
    let client = RecordingHarnessClient()
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client),
      modelContext: container.mainContext
    )
    let sessionID = PreviewFixtures.summary.sessionId

    await store.bootstrap()
    await store.selectSession(sessionID)

    let ended = await store.endSelectedSession()
    #expect(ended)

    let cached = store.loadCachedSessionList()
    let summary = cached?.sessions.first { $0.sessionId == sessionID }
    #expect(summary?.status == .ended)
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
    let store = HarnessMonitorStore(
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
    #expect(store.isBookmarked(sessionId: "sess-bm") == false)
    #expect(store.lastError == "Local persistence is unavailable.")
  }
}
