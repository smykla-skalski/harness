import Foundation

@testable import HarnessMonitorKit

@MainActor
func makeNewSessionStore() -> HarnessMonitorStore {
  HarnessMonitorStore(daemonController: RecordingDaemonController())
}

func makeNewSessionBookmarkStore(containerURL: URL? = nil) -> BookmarkStore {
  let resolvedContainerURL =
    containerURL
    ?? FileManager.default.temporaryDirectory
    .appendingPathComponent("NewSessionBookmarkStore-\(UUID().uuidString)", isDirectory: true)
  return BookmarkStore(containerURL: resolvedContainerURL)
}

func makeNewSessionDaemonStatus(sandboxed: Bool) -> DaemonStatusReport {
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

@MainActor
func makeNewSessionViewModel(
  store: HarnessMonitorStore? = nil,
  bookmarkStore: BookmarkStore? = nil,
  client: any HarnessMonitorClientProtocol = RecordingHarnessClient(),
  isSandboxed: @Sendable @escaping () -> Bool = { true },
  bookmarkResolver: NewSessionViewModel.BookmarkResolver? = nil,
  logSink: (any NewSessionLogSink)? = nil
) -> NewSessionViewModel {
  NewSessionViewModel(
    store: store ?? makeNewSessionStore(),
    bookmarkStore: bookmarkStore ?? makeNewSessionBookmarkStore(),
    client: client,
    isSandboxed: isSandboxed,
    bookmarkResolver: bookmarkResolver,
    logSink: logSink ?? LiveNewSessionLogSink()
  )
}

func stubBookmarkResolver(
  id: String,
  path: String,
  isStale: Bool = false
) -> NewSessionViewModel.BookmarkResolver {
  { receivedID in
    guard receivedID == id else {
      throw BookmarkStoreError.notFound(id: receivedID)
    }
    return NewSessionViewModel.ResolvedBookmark(
      projectDir: path,
      isStale: isStale
    )
  }
}

func failingBookmarkResolver(error: any Error) -> NewSessionViewModel.BookmarkResolver {
  { _ in throw error }
}

final class SpyLogSink: NewSessionLogSink, @unchecked Sendable {
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

final class SpyHarnessClient: HarnessMonitorClientProtocol, @unchecked Sendable {
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
    let currentError = error
    return AsyncThrowingStream { continuation in
      continuation.finish(throwing: currentError)
    }
  }

  nonisolated func sessionStream(sessionID _: String) -> DaemonPushEventStream {
    let currentError = error
    return AsyncThrowingStream { continuation in
      continuation.finish(throwing: currentError)
    }
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

  func startSession(request _: SessionStartRequest) async throws -> SessionStartResult {
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
