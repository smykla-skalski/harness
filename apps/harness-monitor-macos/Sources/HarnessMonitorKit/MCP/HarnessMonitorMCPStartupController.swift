import Foundation
import Observation

public struct HarnessMonitorMCPRecoveryPolicy: Equatable, Sendable {
  public static let `default` = Self(
    maximumRetryCount: 3,
    retryDelay: .seconds(5),
    healthCheckInterval: .seconds(5)
  )

  public let maximumRetryCount: Int
  public let retryDelay: Duration
  public let healthCheckInterval: Duration?

  public init(
    maximumRetryCount: Int = 3,
    retryDelay: Duration = .seconds(5),
    healthCheckInterval: Duration? = .seconds(5)
  ) {
    self.maximumRetryCount = max(0, maximumRetryCount)
    self.retryDelay = retryDelay
    self.healthCheckInterval = healthCheckInterval
  }
}

public struct HarnessMonitorMCPRecoveryStatus: Equatable, Sendable {
  public let completedRetryCount: Int
  public let maximumRetryCount: Int
  public let nextRetryDelay: Duration?

  public init(
    completedRetryCount: Int,
    maximumRetryCount: Int,
    nextRetryDelay: Duration?
  ) {
    self.completedRetryCount = completedRetryCount
    self.maximumRetryCount = maximumRetryCount
    self.nextRetryDelay = nextRetryDelay
  }
}

typealias HarnessMonitorMCPSleep = @Sendable (Duration) async throws -> Void

/// Owns the app-start contract for the in-process MCP accessibility host.
///
/// The controller reconciles the persisted preference at launch, keeps the
/// service in sync with later `UserDefaults` changes, and always performs a
/// final disable on shutdown so stale sockets are cleaned even when the host
/// is turned off.
@MainActor
@Observable
public final class HarnessMonitorMCPStartupController {
  private let service: HarnessMonitorMCPStartupControlling
  private let defaults: UserDefaults
  private let notificationCenter: NotificationCenter
  private let recoveryPolicy: HarnessMonitorMCPRecoveryPolicy
  private let forceEnable: @Sendable () -> Bool
  private let sleep: HarnessMonitorMCPSleep
  private let enabledKey: String
  private let enabledDefault: Bool
  private var observationTask: Task<Void, Never>?
  private var recoveryTask: Task<Void, Never>?
  private var healthCheckTask: Task<Void, Never>?
  private var requestedEnabled = false
  private var completedRetryCount = 0
  @ObservationIgnored private var statusPublicationDepth = 0
  public var statusDidChange: (@MainActor (HarnessMonitorMCPStatusSnapshot) -> Void)? {
    didSet {
      statusDidChange?(statusSnapshot)
    }
  }
  public private(set) var runtimeState: HarnessMonitorMCPRuntimeState {
    didSet {
      guard oldValue != runtimeState else {
        return
      }
      publishStatusIfNeeded()
    }
  }
  public private(set) var recoveryStatus: HarnessMonitorMCPRecoveryStatus? {
    didSet {
      guard oldValue != recoveryStatus else {
        return
      }
      publishStatusIfNeeded()
    }
  }

  public convenience init(
    service: HarnessMonitorMCPStartupControlling = HarnessMonitorMCPAccessibilityService.shared,
    defaults: UserDefaults = .standard,
    notificationCenter: NotificationCenter = .default,
    recoveryPolicy: HarnessMonitorMCPRecoveryPolicy = .default,
    forceEnable: @escaping @Sendable () -> Bool = {
      HarnessMonitorMCPPreferencesDefaults.forceEnableFromEnvironment
    },
    enabledKey: String = HarnessMonitorMCPPreferencesDefaults.registryHostEnabledKey,
    enabledDefault: Bool = HarnessMonitorMCPPreferencesDefaults.registryHostEnabledDefault
  ) {
    self.init(
      service: service,
      defaults: defaults,
      notificationCenter: notificationCenter,
      recoveryPolicy: recoveryPolicy,
      forceEnable: forceEnable,
      sleep: { duration in
        try await Task.sleep(for: duration)
      },
      enabledKey: enabledKey,
      enabledDefault: enabledDefault
    )
  }

  init(
    service: HarnessMonitorMCPStartupControlling,
    defaults: UserDefaults,
    notificationCenter: NotificationCenter,
    recoveryPolicy: HarnessMonitorMCPRecoveryPolicy,
    forceEnable: @escaping @Sendable () -> Bool,
    sleep: @escaping HarnessMonitorMCPSleep,
    enabledKey: String = HarnessMonitorMCPPreferencesDefaults.registryHostEnabledKey,
    enabledDefault: Bool = HarnessMonitorMCPPreferencesDefaults.registryHostEnabledDefault
  ) {
    self.service = service
    self.defaults = defaults
    self.notificationCenter = notificationCenter
    self.recoveryPolicy = recoveryPolicy
    self.forceEnable = forceEnable
    self.sleep = sleep
    self.enabledKey = enabledKey
    self.enabledDefault = enabledDefault
    runtimeState = service.runtimeState
    recoveryStatus = nil
  }

  public func start() {
    guard observationTask == nil else {
      return
    }

    requestedEnabled = effectiveEnabled
    observationTask = Task { @MainActor [weak self] in
      guard let self else {
        return
      }
      defer { self.observationTask = nil }

      await self.applyDesiredEnabled(self.requestedEnabled, resetRecovery: true)

      let notifications = notificationCenter.notifications(
        named: UserDefaults.didChangeNotification,
        object: nil
      )
      for await notification in notifications {
        guard !Task.isCancelled else {
          return
        }
        if let changedDefaults = notification.object as? UserDefaults,
          changedDefaults !== defaults
        {
          continue
        }

        let enabled = self.effectiveEnabled
        guard enabled != self.requestedEnabled else {
          continue
        }
        self.requestedEnabled = enabled
        await self.applyDesiredEnabled(enabled, resetRecovery: true)
      }
    }
  }

  public func stop() async {
    requestedEnabled = false
    let observationTask = observationTask
    self.observationTask = nil
    observationTask?.cancel()
    await cancelHealthCheckTask()
    await cancelRecoveryTask()
    await observationTask?.value
    clearRecoveryState()
    await service.setEnabled(false)
    runtimeState = service.runtimeState
  }

  public func reconcile() async {
    let enabled = effectiveEnabled
    requestedEnabled = enabled
    await applyDesiredEnabled(enabled, resetRecovery: true)
  }

  public var statusSnapshot: HarnessMonitorMCPStatusSnapshot {
    HarnessMonitorMCPStatusSnapshot(
      runtimeState: runtimeState,
      recoveryStatus: recoveryStatus
    )
  }

  private func publishStatusIfNeeded() {
    guard statusPublicationDepth == 0 else {
      return
    }
    statusDidChange?(statusSnapshot)
  }

  private func mutateStatus(_ mutation: () -> Void) {
    statusPublicationDepth += 1
    defer {
      statusPublicationDepth -= 1
      publishStatusIfNeeded()
    }
    mutation()
  }

  private func suspendStatusPublication<Result>(
    _ operation: () async -> Result
  ) async -> Result {
    statusPublicationDepth += 1
    defer {
      statusPublicationDepth -= 1
      publishStatusIfNeeded()
    }
    return await operation()
  }

  private var effectiveEnabled: Bool {
    let storedValue = defaults.object(forKey: enabledKey) as? Bool
    return (storedValue ?? enabledDefault) || forceEnable()
  }

  private func applyDesiredEnabled(_ enabled: Bool, resetRecovery: Bool) async {
    await cancelHealthCheckTask()
    guard enabled else {
      if resetRecovery {
        await cancelRecoveryTask()
        mutateStatus {
          runtimeState = .disabled
          clearRecoveryState()
        }
      } else {
        runtimeState = .disabled
      }
      await service.setEnabled(false)
      runtimeState = service.runtimeState
      return
    }

    if resetRecovery {
      await cancelRecoveryTask()
      clearRecoveryState()
    }

    await attemptEnableForStartupOrRecovery()
  }

  private func attemptEnableForStartupOrRecovery() async {
    runtimeState = .starting(socketPath: service.runtimeState.socketPath)
    await suspendStatusPublication {
      await service.setEnabled(true)
      guard !Task.isCancelled, requestedEnabled else {
        return
      }
      runtimeState = service.runtimeState

      switch runtimeState {
      case .healthy:
        clearRecoveryState()
        startHealthCheckTaskIfNeeded()
      case .degraded:
        await scheduleRecoveryIfNeeded()
      case .disabled, .starting:
        clearRecoveryState()
      }
    }
  }

  private func scheduleRecoveryIfNeeded() async {
    guard requestedEnabled else {
      clearRecoveryState()
      return
    }

    guard completedRetryCount < recoveryPolicy.maximumRetryCount else {
      recoveryStatus = HarnessMonitorMCPRecoveryStatus(
        completedRetryCount: completedRetryCount,
        maximumRetryCount: recoveryPolicy.maximumRetryCount,
        nextRetryDelay: nil
      )
      return
    }

    await cancelRecoveryTask()
    let delay = recoveryPolicy.retryDelay
    recoveryStatus = HarnessMonitorMCPRecoveryStatus(
      completedRetryCount: completedRetryCount,
      maximumRetryCount: recoveryPolicy.maximumRetryCount,
      nextRetryDelay: delay
    )
    let sleep = self.sleep
    recoveryTask = Task { @MainActor [weak self, delay, sleep] in
      do {
        try await sleep(delay)
      } catch is CancellationError {
        return
      } catch {
        return
      }

      guard let self, self.requestedEnabled else {
        return
      }

      self.recoveryTask = nil
      self.completedRetryCount += 1
      await self.attemptEnableForStartupOrRecovery()
    }
  }

  private func startHealthCheckTaskIfNeeded() {
    guard healthCheckTask == nil,
      let interval = recoveryPolicy.healthCheckInterval
    else {
      return
    }

    let sleep = self.sleep
    healthCheckTask = Task { @MainActor [weak self, interval, sleep] in
      while true {
        do {
          try await sleep(interval)
        } catch is CancellationError {
          return
        } catch {
          return
        }

        guard let self, self.requestedEnabled else {
          return
        }

        await self.service.setEnabled(true)
        guard !Task.isCancelled, self.requestedEnabled else {
          return
        }
        await self.suspendStatusPublication {
          self.runtimeState = self.service.runtimeState
          guard case .healthy = self.runtimeState else {
            self.healthCheckTask = nil
            self.completedRetryCount = 0
            await self.scheduleRecoveryIfNeeded()
            return
          }
        }
      }
    }
  }

  private func clearRecoveryState() {
    completedRetryCount = 0
    recoveryStatus = nil
  }

  private func cancelRecoveryTask() async {
    let recoveryTask = recoveryTask
    self.recoveryTask = nil
    recoveryTask?.cancel()
    await recoveryTask?.value
  }

  private func cancelHealthCheckTask() async {
    let healthCheckTask = healthCheckTask
    self.healthCheckTask = nil
    healthCheckTask?.cancel()
    await healthCheckTask?.value
  }
}
