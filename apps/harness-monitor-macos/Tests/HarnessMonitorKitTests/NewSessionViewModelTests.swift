import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("NewSessionViewModel")
struct NewSessionViewModelTests {
  // MARK: - Validation

  @Test("empty title returns titleRequired validation error")
  func emptyTitleReturnsValidationError() async {
    let vm = makeNewSessionViewModel()
    vm.title = ""
    vm.selectedBookmarkId = "B-some-id"
    let result = await vm.submit()
    #expect(result == .failure(.validation(.titleRequired)))
    #expect(vm.lastError == .validation(.titleRequired))
    #expect(vm.isSubmitting == false)
  }

  @Test("whitespace-only title returns titleRequired validation error")
  func whitespaceOnlyTitleReturnsValidationError() async {
    let vm = makeNewSessionViewModel()
    vm.title = "   "
    vm.selectedBookmarkId = "B-some-id"
    let result = await vm.submit()
    #expect(result == .failure(.validation(.titleRequired)))
  }

  @Test("nil selectedBookmarkId returns projectRequired validation error")
  func nilBookmarkIdReturnsProjectRequiredError() async {
    let vm = makeNewSessionViewModel()
    vm.title = "My Session"
    vm.selectedBookmarkId = nil
    let result = await vm.submit()
    #expect(result == .failure(.validation(.projectRequired)))
    #expect(vm.lastError == .validation(.projectRequired))
    #expect(vm.isSubmitting == false)
  }
  // MARK: - Happy path (sandboxed mode)

  @Test("sandboxed mode posts bookmark id as projectDir")
  func sandboxedModePostsBookmarkIdAsProjectDir() async {
    let recordingClient = RecordingHarnessClient()
    let vm = makeNewSessionViewModel(
      client: recordingClient,
      isSandboxed: { true },
      bookmarkResolver: stubBookmarkResolver(
        id: "B-sandbox-id",
        path: "/ignored/in/sandbox"
      )
    )
    vm.title = "Sandbox Session"
    vm.selectedBookmarkId = "B-sandbox-id"
    let result = await vm.submit()
    guard case .success = result else {
      Issue.record("Expected success, got \(result)")
      return
    }
    let startCall = recordingClient.calls.first { call in
      if case .startSession = call { return true }
      return false
    }
    guard case .startSession(let projectDir, _) = startCall else {
      Issue.record("Expected startSession call")
      return
    }
    #expect(projectDir == "B-sandbox-id")
  }

  // MARK: - Happy path (dev/non-sandboxed mode)

  @Test("non-sandboxed mode posts resolved URL path as projectDir")
  func nonSandboxedModePostsResolvedUrlPath() async {
    let recordingClient = RecordingHarnessClient()
    let expectedPath = "/Users/example/Projects/harness"
    let vm = makeNewSessionViewModel(
      client: recordingClient,
      isSandboxed: { false },
      bookmarkResolver: stubBookmarkResolver(
        id: "B-dev-id",
        path: expectedPath
      )
    )
    vm.title = "Dev Session"
    vm.selectedBookmarkId = "B-dev-id"
    let result = await vm.submit()
    guard case .success = result else {
      Issue.record("Expected success, got \(result)")
      return
    }
    let startCall = recordingClient.calls.first { call in
      if case .startSession = call { return true }
      return false
    }
    guard case .startSession(let projectDir, _) = startCall else {
      Issue.record("Expected startSession call")
      return
    }
    #expect(projectDir == expectedPath)
  }

  @Test("daemon manifest sandboxed flag overrides environment guess")
  func daemonManifestSandboxedFlagOverridesEnvironmentGuess() async {
    let recordingClient = RecordingHarnessClient()
    let store = makeNewSessionStore()
    store.daemonStatus = makeNewSessionDaemonStatus(sandboxed: false)
    let expectedPath = "/Users/example/Projects/harness"
    let vm = makeNewSessionViewModel(
      store: store,
      client: recordingClient,
      isSandboxed: { true },
      bookmarkResolver: stubBookmarkResolver(
        id: "B-daemon-manifest",
        path: expectedPath
      )
    )
    vm.title = "Manifest Session"
    vm.selectedBookmarkId = "B-daemon-manifest"

    let result = await vm.submit()

    guard case .success = result else {
      Issue.record("Expected success, got \(result)")
      return
    }
    let startCall = recordingClient.calls.first { call in
      if case .startSession = call { return true }
      return false
    }
    guard case .startSession(let projectDir, _) = startCall else {
      Issue.record("Expected startSession call")
      return
    }
    #expect(projectDir == expectedPath)
  }

  @Test("submit selects newly created awaiting-leader session in the store")
  func submitSelectsNewAwaitingLeaderSessionInStore() async {
    let recordingClient = RecordingHarnessClient()
    recordingClient.configureSessions(summaries: [], detailsByID: [:])
    let store = await makeBootstrappedStore(client: recordingClient)

    let startedSummary = SessionSummary(
      projectId: PreviewFixtures.emptyCockpitSummary.projectId,
      projectName: PreviewFixtures.emptyCockpitSummary.projectName,
      projectDir: PreviewFixtures.emptyCockpitSummary.projectDir,
      contextRoot: PreviewFixtures.emptyCockpitSummary.contextRoot,
      sessionId: "sess-recording-new",
      worktreePath: PreviewFixtures.emptyCockpitSummary.worktreePath,
      sharedPath: PreviewFixtures.emptyCockpitSummary.sharedPath,
      originPath: PreviewFixtures.emptyCockpitSummary.originPath,
      branchRef: "harness/sess-recording-new",
      title: "Created Session",
      context: "new session cockpit",
      status: .awaitingLeader,
      createdAt: "2026-04-22T00:00:00Z",
      updatedAt: "2026-04-22T00:00:00Z",
      lastActivityAt: nil,
      leaderId: nil,
      observeId: nil,
      pendingLeaderTransfer: nil,
      metrics: SessionMetrics(
        agentCount: 0,
        activeAgentCount: 0,
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        completedTaskCount: 0
      )
    )
    let startedDetail = PreviewFixtures.sessionDetail(
      session: startedSummary,
      agents: [],
      tasks: [],
      signals: [],
      observer: nil,
      agentActivity: []
    )
    recordingClient.configureSessions(
      summaries: [startedSummary],
      detailsByID: [startedSummary.sessionId: startedDetail]
    )

    let vm = makeNewSessionViewModel(
      store: store,
      client: recordingClient,
      isSandboxed: { true },
      bookmarkResolver: stubBookmarkResolver(
        id: "B-select",
        path: "/tmp/select"
      )
    )
    vm.title = startedSummary.title
    vm.selectedBookmarkId = "B-select"

    #expect(store.selectedSessionID == nil)

    let result = await vm.submit()

    guard case .success(let startedSession) = result else {
      Issue.record("Expected success, got \(result)")
      return
    }
    #expect(startedSession.sessionId == startedSummary.sessionId)
    #expect(store.selectedSessionID == startedSummary.sessionId)
    #expect(store.selectedSession?.session.sessionId == startedSummary.sessionId)
    #expect(store.selectedSession?.session.status == .awaitingLeader)
  }

  @Test("submit records preferred launch selection after success")
  func submitRecordsPreferredLaunchSelection() async {
    let recordingClient = RecordingHarnessClient()
    final class SelectionBox: @unchecked Sendable {
      private let lock = NSLock()
      private var storage: String?

      func set(_ value: String) {
        lock.lock()
        storage = value
        lock.unlock()
      }

      var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return storage
      }
    }

    let recordedSelection = SelectionBox()
    let vm = makeNewSessionViewModel(
      client: recordingClient,
      isSandboxed: { true },
      bookmarkResolver: stubBookmarkResolver(
        id: "B-selection",
        path: "/tmp/selection"
      ),
      launchPreferenceRecorder: { recordedSelection.set($0) }
    )
    vm.title = "Selection Session"
    vm.selectedBookmarkId = "B-selection"

    let result = await vm.submit(preferredLaunchSelectionStorageKey: "managed:copilot")

    guard case .success = result else {
      Issue.record("Expected success, got \(result)")
      return
    }
    #expect(recordedSelection.value == "managed:copilot")
  }

  // MARK: - URLError mapping

  @Test("URLError.cannotConnectToHost maps to daemonUnreachable")
  func cannotConnectToHostMapsToDaemonUnreachable() async {
    let urlError = URLError(.cannotConnectToHost)
    let spyClient = SpyHarnessClient(error: urlError)
    let vm = makeNewSessionViewModel(
      client: spyClient,
      bookmarkResolver: stubBookmarkResolver(id: "B-x", path: "/tmp/x")
    )
    vm.title = "Test"
    vm.selectedBookmarkId = "B-x"
    let result = await vm.submit()
    #expect(result == .failure(.daemonUnreachable))
    #expect(vm.lastError == .daemonUnreachable)
  }

  @Test("missing daemon client maps to daemonUnreachable before submit")
  func missingClientMapsToDaemonUnreachable() async {
    let vm = makeNewSessionViewModel(
      store: HarnessMonitorStore(daemonController: RecordingDaemonController()),
      client: nil,
      bookmarkResolver: stubBookmarkResolver(id: "B-x", path: "/tmp/x")
    )
    vm.title = "Test"
    vm.selectedBookmarkId = "B-x"

    let result = await vm.submit()

    #expect(result == .failure(.daemonUnreachable))
    #expect(vm.lastError == .daemonUnreachable)
  }

  // MARK: - BookmarkStoreError mapping

  @Test("BookmarkStoreError.unresolvable maps to bookmarkRevoked")
  func unresolvableBookmarkMapsToBookmarkRevoked() async {
    let bookmarkError = BookmarkStoreError.unresolvable(
      id: "B-stale-id",
      underlying: "bookmark data is invalid"
    )
    let vm = makeNewSessionViewModel(
      bookmarkResolver: failingBookmarkResolver(error: bookmarkError)
    )
    vm.title = "Test"
    vm.selectedBookmarkId = "B-stale-id"
    let result = await vm.submit()
    #expect(result == .failure(.bookmarkRevoked(id: "B-stale-id")))
    #expect(vm.lastError == .bookmarkRevoked(id: "B-stale-id"))
  }
}
