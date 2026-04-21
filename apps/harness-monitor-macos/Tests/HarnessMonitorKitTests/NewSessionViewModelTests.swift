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

  @Test("500 response with worktree message maps to worktreeCreateFailed")
  func http500WithWorktreeMessageMapsToWorktreeCreateFailed() async {
    let apiError = HarnessMonitorAPIError.server(
      code: 500,
      message: "failed to create session worktree: path exists"
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

// MARK: - SpyLogSink

private final class SpyLogSink: NewSessionLogSink, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var infoMessages: [String] = []
  private(set) var errorMessages: [String] = []
  private(set) var debugMessages: [String] = []

  func info(_ message: String) {
    lock.lock()
    infoMessages.append(message)
    lock.unlock()
  }

  func error(_ message: String) {
    lock.lock()
    errorMessages.append(message)
    lock.unlock()
  }

  func debug(_ message: String) {
    lock.lock()
    debugMessages.append(message)
    lock.unlock()
  }
}

// MARK: - SpyHarnessClient

private final class SpyHarnessClient: HarnessMonitorClientProtocol, @unchecked Sendable {
  private let error: any Error

  init(error: any Error) {
    self.error = error
  }

  func health() async throws -> HealthResponse { throw error }
  func diagnostics() async throws -> DaemonDiagnosticsReport { throw error }
  func stopDaemon() async throws -> DaemonControlResponse { throw error }
  func projects() async throws -> [ProjectSummary] { throw error }
  func sessions() async throws -> [SessionSummary] { throw error }

  func sessionDetail(
    id _: String,
    scope _: String?
  ) async throws -> SessionDetail { throw error }

  func timeline(sessionID _: String) async throws -> [TimelineEntry] { throw error }

  nonisolated func globalStream() -> DaemonPushEventStream {
    let err = error
    return AsyncThrowingStream { $0.finish(throwing: err) }
  }

  nonisolated func sessionStream(sessionID _: String) -> DaemonPushEventStream {
    let err = error
    return AsyncThrowingStream { $0.finish(throwing: err) }
  }

  func createTask(
    sessionID _: String,
    request _: TaskCreateRequest
  ) async throws -> SessionDetail { throw error }

  func assignTask(
    sessionID _: String,
    taskID _: String,
    request _: TaskAssignRequest
  ) async throws -> SessionDetail { throw error }

  func dropTask(
    sessionID _: String,
    taskID _: String,
    request _: TaskDropRequest
  ) async throws -> SessionDetail { throw error }

  func updateTaskQueuePolicy(
    sessionID _: String,
    taskID _: String,
    request _: TaskQueuePolicyRequest
  ) async throws -> SessionDetail { throw error }

  func updateTask(
    sessionID _: String,
    taskID _: String,
    request _: TaskUpdateRequest
  ) async throws -> SessionDetail { throw error }

  func checkpointTask(
    sessionID _: String,
    taskID _: String,
    request _: TaskCheckpointRequest
  ) async throws -> SessionDetail { throw error }

  func changeRole(
    sessionID _: String,
    agentID _: String,
    request _: RoleChangeRequest
  ) async throws -> SessionDetail { throw error }

  func removeAgent(
    sessionID _: String,
    agentID _: String,
    request _: AgentRemoveRequest
  ) async throws -> SessionDetail { throw error }

  func transferLeader(
    sessionID _: String,
    request _: LeaderTransferRequest
  ) async throws -> SessionDetail { throw error }

  func startSession(request _: SessionStartRequest) async throws -> SessionSummary {
    throw error
  }

  func endSession(
    sessionID _: String,
    request _: SessionEndRequest
  ) async throws -> SessionDetail { throw error }

  func sendSignal(
    sessionID _: String,
    request _: SignalSendRequest
  ) async throws -> SessionDetail { throw error }

  func cancelSignal(
    sessionID _: String,
    request _: SignalCancelRequest
  ) async throws -> SessionDetail { throw error }

  func observeSession(
    sessionID _: String,
    request _: ObserveSessionRequest
  ) async throws -> SessionDetail { throw error }

  func logLevel() async throws -> LogLevelResponse { throw error }
  func setLogLevel(_: String) async throws -> LogLevelResponse { throw error }
}
