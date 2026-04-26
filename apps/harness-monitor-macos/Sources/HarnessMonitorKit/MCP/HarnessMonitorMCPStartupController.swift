import Foundation
import Observation

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
  private let forceEnable: @Sendable () -> Bool
  private let enabledKey: String
  private let enabledDefault: Bool
  private var observationTask: Task<Void, Never>?
  public private(set) var runtimeState: HarnessMonitorMCPRuntimeState

  public init(
    service: HarnessMonitorMCPStartupControlling = HarnessMonitorMCPAccessibilityService.shared,
    defaults: UserDefaults = .standard,
    notificationCenter: NotificationCenter = .default,
    forceEnable: @escaping @Sendable () -> Bool = {
      HarnessMonitorMCPPreferencesDefaults.forceEnableFromEnvironment
    },
    enabledKey: String = HarnessMonitorMCPPreferencesDefaults.registryHostEnabledKey,
    enabledDefault: Bool = HarnessMonitorMCPPreferencesDefaults.registryHostEnabledDefault
  ) {
    self.service = service
    self.defaults = defaults
    self.notificationCenter = notificationCenter
    self.forceEnable = forceEnable
    self.enabledKey = enabledKey
    self.enabledDefault = enabledDefault
    runtimeState = service.runtimeState
  }

  public func start() {
    guard observationTask == nil else {
      return
    }

    observationTask = Task { @MainActor [weak self] in
      guard let self else {
        return
      }

      await self.reconcile()

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
        await self.reconcile()
      }
    }
  }

  public func stop() async {
    let observationTask = observationTask
    self.observationTask = nil
    observationTask?.cancel()
    await observationTask?.value
    await service.setEnabled(false)
    runtimeState = service.runtimeState
  }

  public func reconcile() async {
    let enabled = effectiveEnabled
    if enabled {
      if case .healthy = service.runtimeState {
        runtimeState = service.runtimeState
      } else {
        runtimeState = .starting(socketPath: service.runtimeState.socketPath)
      }
    } else {
      runtimeState = .disabled
    }

    await service.setEnabled(enabled)
    runtimeState = service.runtimeState
  }

  private var effectiveEnabled: Bool {
    let storedValue = defaults.object(forKey: enabledKey) as? Bool
    return (storedValue ?? enabledDefault) || forceEnable()
  }
}
