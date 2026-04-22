import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("NewSessionViewModel")
struct NewSessionViewModelTests {
  // MARK: - Helpers
  private func makeStore() -> HarnessMonitorStore {
    HarnessMonitorStore(daemonController: RecordingDaemonController())
  }
  private func makeBookmarkStore() -> BookmarkStore {
    BookmarkStore(containerURL: FileManager.default.temporaryDirectory)
  }
  private func makeDaemonStatus(sandboxed: Bool) -> DaemonStatusReport {
    DaemonStatusReport(
      manifest: DaemonManifest(
        version: "28.6.2",
        pid: 1,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-04-22T00:00:00Z",
        tokenPath: "/tmp/token",
        sandboxed: sandboxed
      ),
      launchAgent: LaunchAgentStatus(
        installed: true,
        label: "io.harnessmonitor.daemon",
        path: "/tmp/io.harnessmonitor.daemon.plist"
      ),
      projectCount: 1,
      sessionCount: 0,
      diagnostics: DaemonDiagnostics(
        daemonRoot: "/tmp/harness/daemon",
        manifestPath: "/tmp/harness/daemon/manifest.json",
        authTokenPath: "/tmp/token",
        authTokenPresent: true,
        eventsPath: "/tmp/harness/daemon/events.jsonl",
        databasePath: "/tmp/harness/daemon/harness.db",
        databaseSizeBytes: 0,
        lastEvent: nil
      )
    )
  }
  private func makeViewModel(
    store: HarnessMonitorStore? = nil,
    client: any HarnessMonitorClientProtocol = RecordingHarnessClient(),
    isSandboxed: @Sendable @escaping () -> Bool = { true },
    bookmarkResolver: NewSessionViewModel.BookmarkResolver? = nil,
    logSink: (any NewSessionLogSink)? = nil
  ) -> NewSessionViewModel {
    let resolvedStore = store ?? makeStore()
    let bookmarkStore = makeBookmarkStore()
    return NewSessionViewModel(
      store: resolvedStore,
      bookmarkStore: bookmarkStore,
      client: client,
      isSandboxed: isSandboxed,
      bookmarkResolver: bookmarkResolver,
      logSink: logSink ?? LiveNewSessionLogSink()
    )
  }

  private func stubResolver(
    id: String,
    path: String,
    isStale: Bool = false
  ) -> NewSessionViewModel.BookmarkResolver {
    { receivedId in
      guard receivedId == id else {
        throw BookmarkStoreError.notFound(id: receivedId)
      }
      return NewSessionViewModel.ResolvedBookmark(
        projectDir: path,
        isStale: isStale
      )
    }
  }

  private func failingResolver(error: any Error) -> NewSessionViewModel.BookmarkResolver {
    { _ in throw error }
  }
  // MARK: - Validation

  @Test("empty title returns titleRequired validation error")
  func emptyTitleReturnsValidationError() async {
    let vm = makeViewModel()
    vm.title = ""
    vm.selectedBookmarkId = "B-some-id"
    let result = await vm.submit()
    #expect(result == .failure(.validation(.titleRequired)))
    #expect(vm.lastError == .validation(.titleRequired))
    #expect(vm.isSubmitting == false)
  }

  @Test("whitespace-only title returns titleRequired validation error")
  func whitespaceOnlyTitleReturnsValidationError() async {
    let vm = makeViewModel()
    vm.title = "   "
    vm.selectedBookmarkId = "B-some-id"
    let result = await vm.submit()
    #expect(result == .failure(.validation(.titleRequired)))
  }

  @Test("nil selectedBookmarkId returns projectRequired validation error")
  func nilBookmarkIdReturnsProjectRequiredError() async {
    let vm = makeViewModel()
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
    let vm = makeViewModel(
      client: recordingClient,
      isSandboxed: { true },
      bookmarkResolver: stubResolver(
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
    guard case .startSession(let projectDir, _, _) = startCall else {
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
    let vm = makeViewModel(
      client: recordingClient,
      isSandboxed: { false },
      bookmarkResolver: stubResolver(
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
    guard case .startSession(let projectDir, _, _) = startCall else {
      Issue.record("Expected startSession call")
      return
    }
    #expect(projectDir == expectedPath)
  }

  @Test("daemon manifest sandboxed flag overrides environment guess")
  func daemonManifestSandboxedFlagOverridesEnvironmentGuess() async {
    let recordingClient = RecordingHarnessClient()
    let store = makeStore()
    store.daemonStatus = makeDaemonStatus(sandboxed: false)
    let expectedPath = "/Users/example/Projects/harness"
    let vm = makeViewModel(
      store: store,
      client: recordingClient,
      isSandboxed: { true },
      bookmarkResolver: stubResolver(
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
    guard case .startSession(let projectDir, _, _) = startCall else {
      Issue.record("Expected startSession call")
      return
    }
    #expect(projectDir == expectedPath)
  }

  // MARK: - URLError mapping

  @Test("URLError.cannotConnectToHost maps to daemonUnreachable")
  func cannotConnectToHostMapsToDaemonUnreachable() async {
    let urlError = URLError(.cannotConnectToHost)
    let spyClient = SpyHarnessClient(error: urlError)
    let vm = makeViewModel(
      client: spyClient,
      bookmarkResolver: stubResolver(id: "B-x", path: "/tmp/x")
    )
    vm.title = "Test"
    vm.selectedBookmarkId = "B-x"
    let result = await vm.submit()
    #expect(result == .failure(.daemonUnreachable))
    #expect(vm.lastError == .daemonUnreachable)
  }
  // MARK: - HTTP 500 worktree error mapping

  @Test("server response with worktree message maps to worktreeCreateFailed")
  func serverResponseWithWorktreeMessageMapsToWorktreeCreateFailed() async {
    let apiError = HarnessMonitorAPIError.server(
      code: 400,
      message: "create session worktree: worktree create failed: path exists"
    )
    let spyClient = SpyHarnessClient(error: apiError)
    let vm = makeViewModel(
      client: spyClient,
      bookmarkResolver: stubResolver(id: "B-x", path: "/tmp/x")
    )
    vm.title = "Test"
    vm.selectedBookmarkId = "B-x"
    let result = await vm.submit()
    guard case .failure(.worktreeCreateFailed(let reason)) = result else {
      Issue.record("Expected worktreeCreateFailed, got \(result)")
      return
    }
    #expect(reason.contains("create session worktree"))
  }

  @Test("400 response with no HEAD maps to invalidProject")
  func http400WithNoHeadMapsToInvalidProject() async {
    let apiError = HarnessMonitorAPIError.server(
      code: 400,
      message: "create session worktree: worktree create failed: no HEAD"
    )
    let spyClient = SpyHarnessClient(error: apiError)
    let vm = makeViewModel(
      client: spyClient,
      bookmarkResolver: stubResolver(id: "B-x", path: "/tmp/x")
    )
    vm.title = "Test"
    vm.selectedBookmarkId = "B-x"

    let result = await vm.submit()

    guard case .failure(.invalidProject(let reason)) = result else {
      Issue.record("Expected invalidProject, got \(result)")
      return
    }
    #expect(reason.contains("no HEAD"))
    #expect(vm.lastError == .invalidProject(reason: reason))
  }

  @Test("websocket no HEAD maps to invalidProject")
  func websocketNoHeadMapsToInvalidProject() async {
    let transportError = WebSocketTransportError.serverError(
      code: "WORKFLOW_IO",
      message: "create session worktree: worktree create failed: no HEAD"
    )
    let spyClient = SpyHarnessClient(error: transportError)
    let vm = makeViewModel(
      client: spyClient,
      bookmarkResolver: stubResolver(id: "B-x", path: "/tmp/x")
    )
    vm.title = "Test"
    vm.selectedBookmarkId = "B-x"

    let result = await vm.submit()

    guard case .failure(.invalidProject(let reason)) = result else {
      Issue.record("Expected invalidProject, got \(result)")
      return
    }
    #expect(reason.contains("no HEAD"))
  }

  @Test("websocket invalid reference maps to invalidBaseRef")
  func websocketInvalidReferenceMapsToInvalidBaseRef() async {
    let transportError = WebSocketTransportError.serverError(
      code: "WORKFLOW_IO",
      message: "create session worktree: worktree create failed: fatal: invalid reference: origin/main"
    )
    let spyClient = SpyHarnessClient(error: transportError)
    let vm = makeViewModel(
      client: spyClient,
      bookmarkResolver: stubResolver(id: "B-x", path: "/tmp/x")
    )
    vm.title = "Test"
    vm.selectedBookmarkId = "B-x"
    vm.baseRef = "origin/main"

    let result = await vm.submit()

    guard case .failure(.invalidBaseRef(let ref, let reason)) = result else {
      Issue.record("Expected invalidBaseRef, got \(result)")
      return
    }
    #expect(ref == "origin/main")
    #expect(reason.contains("invalid reference"))
  }

  @Test("websocket bookmark resolution failure maps to bookmarkRevoked")
  func websocketBookmarkResolutionFailureMapsToBookmarkRevoked() async {
    let transportError = WebSocketTransportError.serverError(
      code: "WORKFLOW_IO",
      message:
        "resolve bookmark 'B-x': resolution failed: CFURLCreateByResolvingBookmarkData failed: code=259 description=The file couldn’t be opened because it isn’t in the correct format."
    )
    let spyClient = SpyHarnessClient(error: transportError)
    let vm = makeViewModel(
      client: spyClient,
      bookmarkResolver: stubResolver(id: "B-x", path: "/tmp/x")
    )
    vm.title = "Test"
    vm.selectedBookmarkId = "B-x"

    let result = await vm.submit()

    #expect(result == .failure(.bookmarkRevoked(id: "B-x")))
    #expect(vm.lastError == .bookmarkRevoked(id: "B-x"))
  }

  // MARK: - BookmarkStoreError mapping

  @Test("BookmarkStoreError.unresolvable maps to bookmarkRevoked")
  func unresolvableBookmarkMapsToBookmarkRevoked() async {
    let bookmarkError = BookmarkStoreError.unresolvable(
      id: "B-stale-id",
      underlying: "bookmark data is invalid"
    )
    let vm = makeViewModel(
      bookmarkResolver: failingResolver(error: bookmarkError)
    )
    vm.title = "Test"
    vm.selectedBookmarkId = "B-stale-id"
    let result = await vm.submit()
    #expect(result == .failure(.bookmarkRevoked(id: "B-stale-id")))
    #expect(vm.lastError == .bookmarkRevoked(id: "B-stale-id"))
  }

  // MARK: - availableBookmarks

  @Test("availableBookmarks returns only projectRoot bookmarks from empty store")
  func availableBookmarksFiltersToProjectRoot() async {
    let vm = makeViewModel()

    let bookmarks = await vm.availableBookmarks()

    #expect(bookmarks.isEmpty)
  }

  // MARK: - lastError cleared on success

  @Test("lastError is nil after successful submit following a prior error")
  func lastErrorClearedAfterSuccess() async {
    let vm = makeViewModel(
      bookmarkResolver: stubResolver(id: "B-ok", path: "/tmp/ok")
    )
    vm.title = ""
    vm.selectedBookmarkId = "B-ok"
    _ = await vm.submit()
    #expect(vm.lastError == .validation(.titleRequired))

    vm.title = "Good Title"
    let result = await vm.submit()

    guard case .success = result else {
      Issue.record("Expected success, got \(result)")
      return
    }
    #expect(vm.lastError == nil)
  }

  // MARK: - Log sink

  @Test("submit emits started and succeeded logs on happy path")
  func submitEmitsStartedAndSucceededLogsOnHappyPath() async {
    let spy = SpyLogSink()
    let vm = makeViewModel(
      bookmarkResolver: stubResolver(id: "B-log", path: "/tmp/log"),
      logSink: spy
    )
    vm.title = "Logged Session"
    vm.selectedBookmarkId = "B-log"

    _ = await vm.submit()

    #expect(spy.infoMessages.contains("new-session submit started"))
    #expect(spy.infoMessages.contains { $0.hasPrefix("new-session submit succeeded id=") })
  }

  @Test("submit emits error log on daemon unreachable")
  func submitEmitsErrorLogOnDaemonUnreachable() async {
    let spy = SpyLogSink()
    let spyClient = SpyHarnessClient(error: URLError(.cannotConnectToHost))
    let vm = makeViewModel(
      client: spyClient,
      bookmarkResolver: stubResolver(id: "B-err", path: "/tmp/err"),
      logSink: spy
    )
    vm.title = "Fail Session"
    vm.selectedBookmarkId = "B-err"

    _ = await vm.submit()

    #expect(spy.errorMessages.contains { $0.contains("kind=daemonUnreachable") })
  }
}
