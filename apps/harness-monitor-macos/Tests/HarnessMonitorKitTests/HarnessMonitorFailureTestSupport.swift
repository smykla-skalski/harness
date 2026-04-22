import Foundation
import Observation

@testable import HarnessMonitorKit

private final class ObservationInvalidationFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var invalidated = false

  func markInvalidated() {
    lock.lock()
    invalidated = true
    lock.unlock()
  }

  func currentValue() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return invalidated
  }
}

private final class ObservationInvalidationCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }

  func currentValue() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}

@MainActor
private final class ObservationTrackingLoop<TrackedValue>: @unchecked Sendable {
  private let trackedValue: () -> TrackedValue
  private let counter = ObservationInvalidationCounter()
  private var isTracking = true

  init(trackedValue: @escaping () -> TrackedValue) {
    self.trackedValue = trackedValue
  }

  func arm() {
    guard isTracking else {
      return
    }
    _ = withObservationTracking(
      {
        trackedValue()
      },
      onChange: { [weak self] in
        MainActor.assumeIsolated {
          guard let self else {
            return
          }
          self.counter.increment()
          self.arm()
        }
      }
    )
  }

  func stop() {
    isTracking = false
  }

  func currentCount() -> Int {
    counter.currentValue()
  }
}

actor FailingDaemonController: DaemonControlling {
  private let bootstrapError: (any Error)?
  private let actionError: (any Error)?

  init(
    bootstrapError: (any Error)? = nil,
    actionError: (any Error)? = nil
  ) {
    self.bootstrapError = bootstrapError
    self.actionError = actionError
  }

  func bootstrapClient() async throws -> any HarnessMonitorClientProtocol {
    if let bootstrapError {
      throw bootstrapError
    }
    return PreviewHarnessClient()
  }

  func registerLaunchAgent() async throws -> DaemonLaunchAgentRegistrationState {
    if let actionError {
      throw actionError
    }
    return .enabled
  }

  func launchAgentRegistrationState() async -> DaemonLaunchAgentRegistrationState {
    .enabled
  }

  func launchAgentSnapshot() async -> LaunchAgentStatus {
    LaunchAgentStatus(
      installed: true,
      loaded: true,
      label: "io.harness.daemon",
      path: "/tmp/io.harness.daemon.plist"
    )
  }

  func awaitLaunchAgentState(
    _ target: DaemonLaunchAgentRegistrationState,
    timeout: Duration
  ) async throws {
    if let actionError {
      throw actionError
    }
  }

  func awaitManifestWarmUp(
    timeout: Duration
  ) async throws -> any HarnessMonitorClientProtocol {
    if let bootstrapError {
      throw bootstrapError
    }
    return PreviewHarnessClient()
  }

  func performDeferredManagedLaunchAgentRefreshIfNeeded() async -> Bool {
    false
  }

  func stopDaemon() async throws -> String {
    if let actionError {
      throw actionError
    }
    return "stopped"
  }

  func daemonStatus() async throws -> DaemonStatusReport {
    throw DaemonControlError.manifestMissing
  }

  func installLaunchAgent() async throws -> String {
    if let actionError {
      throw actionError
    }
    return "/tmp/test.plist"
  }

  func removeLaunchAgent() async throws -> String {
    if let actionError {
      throw actionError
    }
    return "removed"
  }
}

final class FailingHarnessClient: HarnessMonitorClientProtocol, @unchecked Sendable {
  private let error: any Error

  init(error: any Error = HarnessMonitorAPIError.server(code: 500, message: "internal error")) {
    self.error = error
  }

  func health() async throws -> HealthResponse { throw error }
  func diagnostics() async throws -> DaemonDiagnosticsReport { throw error }
  func stopDaemon() async throws -> DaemonControlResponse { throw error }
  func projects() async throws -> [ProjectSummary] { throw error }
  func sessions() async throws -> [SessionSummary] { throw error }
  func sessionDetail(id _: String, scope _: String?) async throws -> SessionDetail { throw error }
  func timeline(sessionID _: String) async throws -> [TimelineEntry] { throw error }

  nonisolated func globalStream() -> DaemonPushEventStream {
    AsyncThrowingStream { $0.finish(throwing: self.error) }
  }

  nonisolated func sessionStream(sessionID _: String) -> DaemonPushEventStream {
    AsyncThrowingStream { $0.finish(throwing: self.error) }
  }

  func createTask(sessionID _: String, request _: TaskCreateRequest) async throws -> SessionDetail {
    throw error
  }

  func assignTask(
    sessionID _: String, taskID _: String, request _: TaskAssignRequest
  ) async throws -> SessionDetail { throw error }

  func dropTask(
    sessionID _: String, taskID _: String, request _: TaskDropRequest
  ) async throws -> SessionDetail { throw error }

  func updateTaskQueuePolicy(
    sessionID _: String, taskID _: String, request _: TaskQueuePolicyRequest
  ) async throws -> SessionDetail { throw error }

  func updateTask(
    sessionID _: String, taskID _: String, request _: TaskUpdateRequest
  ) async throws -> SessionDetail { throw error }

  func checkpointTask(
    sessionID _: String, taskID _: String, request _: TaskCheckpointRequest
  ) async throws -> SessionDetail { throw error }

  func changeRole(
    sessionID _: String, agentID _: String, request _: RoleChangeRequest
  ) async throws -> SessionDetail { throw error }

  func removeAgent(
    sessionID _: String, agentID _: String, request _: AgentRemoveRequest
  ) async throws -> SessionDetail { throw error }

  func transferLeader(
    sessionID _: String, request _: LeaderTransferRequest
  ) async throws -> SessionDetail { throw error }

  func startSession(request _: SessionStartRequest) async throws -> SessionSummary { throw error }

  func endSession(
    sessionID _: String, request _: SessionEndRequest
  ) async throws -> SessionDetail { throw error }

  func sendSignal(
    sessionID _: String, request _: SignalSendRequest
  ) async throws -> SessionDetail { throw error }

  func cancelSignal(
    sessionID _: String, request _: SignalCancelRequest
  ) async throws -> SessionDetail { throw error }

  func observeSession(
    sessionID _: String, request _: ObserveSessionRequest
  ) async throws -> SessionDetail { throw error }

  func logLevel() async throws -> LogLevelResponse { throw error }
  func setLogLevel(_ level: String) async throws -> LogLevelResponse { throw error }
}

@MainActor
func makeBootstrappedStore(
  client: any HarnessMonitorClientProtocol = RecordingHarnessClient()
) async -> HarnessMonitorStore {
  let daemon = RecordingDaemonController(client: client)
  let store = HarnessMonitorStore(daemonController: daemon)
  await store.bootstrap()
  return store
}

@MainActor
extension HarnessMonitorStore {
  var currentSuccessFeedbackMessage: String? {
    toast.activeFeedback.first { $0.severity == .success }?.message
  }

  var currentFailureFeedbackMessage: String? {
    toast.activeFeedback.first { $0.severity == .failure }?.message
  }
}

@MainActor
func didInvalidate<TrackedValue>(
  _ trackedValue: @escaping () -> TrackedValue,
  after mutation: () async -> Void
) async -> Bool {
  await invalidationCount(trackedValue, after: mutation) > 0
}

@MainActor
func invalidationCount<TrackedValue>(
  _ trackedValue: @escaping () -> TrackedValue,
  after mutation: () async -> Void
) async -> Int {
  let trackingLoop = ObservationTrackingLoop(trackedValue: trackedValue)
  trackingLoop.arm()
  await mutation()
  await Task.yield()
  await Task.yield()
  trackingLoop.stop()

  return trackingLoop.currentCount()
}

@MainActor
func didInvalidate<TrackedValue>(
  _ trackedValue: @escaping () -> TrackedValue,
  after mutation: () -> Void
) async -> Bool {
  let flag = ObservationInvalidationFlag()
  _ = withObservationTracking(
    {
      trackedValue()
    },
    onChange: {
      flag.markInvalidated()
    }
  )
  mutation()
  await Task.yield()
  await Task.yield()
  return flag.currentValue()
}
