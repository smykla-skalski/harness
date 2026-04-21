import Foundation

@testable import HarnessMonitorKit

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
