import AppKit
import Foundation

private struct LegacyContainmentConfiguration: Sendable {
  let controller: any DaemonControlling
  let onFailure: @Sendable (String, UUID) async -> Void
  let onRecovery: @Sendable (Bool, UInt64) async -> Void
}

private struct LegacyContainmentRecoveryOutcome {
  let recovered: Bool
  let reconnectAuthorized: Bool
  let recheck: Bool
  let requestGeneration: UInt64
}

private final class LegacyContainmentState: @unchecked Sendable {
  let lock = NSLock()
  var configuration: LegacyContainmentConfiguration?
  var task: Task<Void, Never>?
  var taskID: UUID?
  var failureActive = false
  var recoveryAuthorized = true
  var recheckRequested = false
  var waitingForRetry = false
  var requestGeneration: UInt64 = 0
  var observers: [(NotificationCenter, NSObjectProtocol)] = []
}

final class LegacyManagedLaunchAgentContainment: @unchecked Sendable {
  private enum CheckDisposition {
    case stop
    case retryNow
    case retryAfterDelay
  }

  private let state = LegacyContainmentState()
  private let initialRetryDelay: Duration
  private let maximumRetryDelay: Duration

  init(
    initialRetryDelay: Duration = .seconds(1),
    maximumRetryDelay: Duration = .seconds(30)
  ) {
    self.initialRetryDelay = initialRetryDelay
    self.maximumRetryDelay = maximumRetryDelay
  }

  @MainActor
  func start(
    controller: any DaemonControlling,
    failureActive: Bool,
    recoveryAuthorized: Bool = true,
    onFailure: @escaping @Sendable (String, UUID) async -> Void,
    onRecovery: @escaping @Sendable (Bool, UInt64) async -> Void
  ) {
    let shouldInstallObservers = state.lock.withLock { () -> Bool in
      state.configuration = LegacyContainmentConfiguration(
        controller: controller,
        onFailure: onFailure,
        onRecovery: onRecovery
      )
      state.failureActive = state.failureActive || failureActive
      state.recoveryAuthorized = state.recoveryAuthorized && recoveryAuthorized
      return state.observers.isEmpty
    }
    if shouldInstallObservers {
      installObservers()
    }
    if failureActive {
      requestCheck(recoveryAuthorized: recoveryAuthorized)
    }
  }

  func requestCheck(
    recoveryAuthorized: Bool = true,
    invalidatingLegacyMonitorProcessScan: Bool = false
  ) {
    let initialRetryDelay = initialRetryDelay
    let maximumRetryDelay = maximumRetryDelay
    let state = state
    if invalidatingLegacyMonitorProcessScan {
      state.lock.withLock { state.configuration }?
        .controller.invalidateLegacyMonitorProcessScan()
    }
    state.lock.withLock {
      guard state.configuration != nil else { return }
      state.requestGeneration &+= 1
      state.recoveryAuthorized = state.recoveryAuthorized && recoveryAuthorized
      if state.task != nil {
        state.recheckRequested = true
        if state.waitingForRetry {
          state.task?.cancel()
        }
        return
      }
      let id = UUID()
      state.taskID = id
      state.task = Task.detached(priority: .background) {
        await Self.runChecks(
          state: state,
          taskID: id,
          initialRetryDelay: initialRetryDelay,
          maximumRetryDelay: maximumRetryDelay
        )
      }
    }
  }

  @MainActor
  private func installObservers() {
    let workspaceCenter = NSWorkspace.shared.notificationCenter
    let defaultCenter = NotificationCenter.default
    let workspaceNames: [Notification.Name] = [
      NSWorkspace.didLaunchApplicationNotification,
      NSWorkspace.didTerminateApplicationNotification,
      NSWorkspace.didWakeNotification,
    ]
    let workspaceObservers = workspaceNames.map { name in
      let observer = workspaceCenter.addObserver(
        forName: name,
        object: nil,
        queue: nil
      ) { [weak self] notification in
        guard
          name == NSWorkspace.didWakeNotification
            || Self.shouldCheckApplicationLifecycle(notification)
        else {
          return
        }
        self?.requestCheck(
          invalidatingLegacyMonitorProcessScan:
            Self.invalidatesLegacyMonitorProcessScan(for: name)
        )
      }
      return (
        workspaceCenter,
        observer
      )
    }
    let activeObserver = (
      defaultCenter,
      defaultCenter.addObserver(
        forName: NSApplication.didBecomeActiveNotification,
        object: nil,
        queue: nil
      ) { [weak self] _ in
        self?.requestCheck()
      }
    )
    state.lock.withLock {
      state.observers.append(contentsOf: workspaceObservers + [activeObserver])
    }
  }

  private static func shouldCheckApplicationLifecycle(_ notification: Notification) -> Bool {
    guard
      let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
        as? NSRunningApplication
    else {
      return false
    }
    return shouldCheckApplicationLifecycle(bundleIdentifier: application.bundleIdentifier)
  }

  static func shouldCheckApplicationLifecycle(bundleIdentifier: String?) -> Bool {
    bundleIdentifier?.hasPrefix("io.harnessmonitor.app") == true
  }

  static func invalidatesLegacyMonitorProcessScan(for notificationName: Notification.Name) -> Bool {
    notificationName == NSWorkspace.didLaunchApplicationNotification
      || notificationName == NSWorkspace.didTerminateApplicationNotification
  }

  private static func runChecks(
    state: LegacyContainmentState,
    taskID: UUID,
    initialRetryDelay: Duration,
    maximumRetryDelay: Duration
  ) async {
    var retryDelay = initialRetryDelay
    while !Task.isCancelled {
      guard let configuration = state.lock.withLock({ state.configuration }) else {
        break
      }
      switch await runCheck(state: state, taskID: taskID, configuration: configuration) {
      case .stop:
        finishRun(
          state: state,
          taskID: taskID,
          initialRetryDelay: initialRetryDelay,
          maximumRetryDelay: maximumRetryDelay
        )
        return
      case .retryNow:
        retryDelay = initialRetryDelay
      case .retryAfterDelay:
        guard await waitForRetry(state: state, taskID: taskID, delay: retryDelay) else {
          break
        }
        retryDelay = min(retryDelay * 2, maximumRetryDelay)
      }
    }
    finishRun(
      state: state,
      taskID: taskID,
      initialRetryDelay: initialRetryDelay,
      maximumRetryDelay: maximumRetryDelay
    )
  }

  private static func runCheck(
    state: LegacyContainmentState,
    taskID: UUID,
    configuration: LegacyContainmentConfiguration
  ) async -> CheckDisposition {
    do {
      try await configuration.controller.requireLegacyManagedLaunchAgentCleanup()
      return await handleSuccessfulCheck(
        state: state,
        taskID: taskID,
        configuration: configuration
      )
    } catch is CancellationError {
      return .stop
    } catch {
      return await handleFailedCheck(
        error,
        state: state,
        taskID: taskID,
        configuration: configuration
      )
    }
  }

  private static func handleSuccessfulCheck(
    state: LegacyContainmentState,
    taskID: UUID,
    configuration: LegacyContainmentConfiguration
  ) async -> CheckDisposition {
    let outcome = state.lock.withLock { () -> LegacyContainmentRecoveryOutcome in
      if state.recheckRequested {
        state.recheckRequested = false
        return LegacyContainmentRecoveryOutcome(
          recovered: false,
          reconnectAuthorized: false,
          recheck: true,
          requestGeneration: state.requestGeneration
        )
      }
      let recovered = state.failureActive
      let reconnectAuthorized = recovered && state.recoveryAuthorized
      let requestGeneration = state.requestGeneration
      if state.taskID == taskID {
        state.task = nil
        state.taskID = nil
      }
      return LegacyContainmentRecoveryOutcome(
        recovered: recovered,
        reconnectAuthorized: reconnectAuthorized,
        recheck: false,
        requestGeneration: requestGeneration
      )
    }
    if outcome.recovered {
      await configuration.onRecovery(
        outcome.reconnectAuthorized,
        outcome.requestGeneration
      )
    }
    return outcome.recheck ? .retryNow : .stop
  }

  func claimRecovery(requestGeneration: UInt64) -> Bool {
    state.lock.withLock {
      guard
        state.requestGeneration == requestGeneration,
        state.failureActive,
        state.recheckRequested == false
      else {
        return false
      }
      state.failureActive = false
      state.recoveryAuthorized = true
      return true
    }
  }

  func claimFailure(taskID: UUID) -> Bool {
    state.lock.withLock {
      state.taskID == taskID
        && state.configuration != nil
        && state.failureActive
    }
  }

  private static func handleFailedCheck(
    _ error: any Error,
    state: LegacyContainmentState,
    taskID: UUID,
    configuration: LegacyContainmentConfiguration
  ) async -> CheckDisposition {
    let shouldNotify = state.lock.withLock { () -> Bool? in
      guard
        state.taskID == taskID,
        state.configuration != nil,
        !Task.isCancelled
      else {
        return nil
      }
      let shouldNotify = !state.failureActive
      state.failureActive = true
      return shouldNotify
    }
    guard let shouldNotify else { return .stop }
    if shouldNotify {
      guard
        !Task.isCancelled,
        state.lock.withLock({ state.taskID == taskID && state.configuration != nil })
      else {
        return .stop
      }
      await configuration.onFailure(error.localizedDescription, taskID)
    }
    let shouldSleep = state.lock.withLock { () -> Bool in
      if state.recheckRequested {
        state.recheckRequested = false
        return false
      }
      guard state.taskID == taskID else { return false }
      state.waitingForRetry = true
      return true
    }
    return shouldSleep ? .retryAfterDelay : .retryNow
  }

  private static func waitForRetry(
    state: LegacyContainmentState,
    taskID: UUID,
    delay: Duration
  ) async -> Bool {
    do {
      try await Task.sleep(for: delay)
    } catch {
      clearRetryWait(state: state, taskID: taskID)
      return false
    }
    clearRetryWait(state: state, taskID: taskID)
    return true
  }

  private static func clearRetryWait(state: LegacyContainmentState, taskID: UUID) {
    state.lock.withLock {
      if state.taskID == taskID {
        state.waitingForRetry = false
      }
    }
  }

  private static func finishRun(
    state: LegacyContainmentState,
    taskID: UUID,
    initialRetryDelay: Duration,
    maximumRetryDelay: Duration
  ) {
    state.lock.withLock {
      guard state.taskID == taskID else { return }
      state.task = nil
      state.taskID = nil
      state.waitingForRetry = false
      guard state.configuration != nil, state.recheckRequested else { return }
      state.recheckRequested = false
      let nextID = UUID()
      state.taskID = nextID
      state.task = Task.detached(priority: .background) {
        await runChecks(
          state: state,
          taskID: nextID,
          initialRetryDelay: initialRetryDelay,
          maximumRetryDelay: maximumRetryDelay
        )
      }
    }
  }

  func cancel() {
    let stopped = state.lock.withLock {
      let activeTask = state.task
      let activeObservers = state.observers
      state.task = nil
      state.taskID = nil
      state.configuration = nil
      state.observers = []
      state.failureActive = false
      state.recoveryAuthorized = true
      state.recheckRequested = false
      state.waitingForRetry = false
      return (activeTask, activeObservers)
    }
    stopped.0?.cancel()
    for (center, observer) in stopped.1 {
      center.removeObserver(observer)
    }
  }

  deinit {
    cancel()
  }
}
