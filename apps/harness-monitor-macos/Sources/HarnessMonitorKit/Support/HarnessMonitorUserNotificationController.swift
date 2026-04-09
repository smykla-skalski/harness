import Foundation
import Observation
import UserNotifications

@MainActor
@Observable
public final class HarnessMonitorUserNotificationController: NSObject,
  UNUserNotificationCenterDelegate
{
  public var draft = HarnessMonitorNotificationDraft()
  public private(set) var settingsSnapshot = HarnessMonitorNotificationSettingsSnapshot.unknown
  public private(set) var pendingRequestCount = 0
  public private(set) var deliveredNotificationCount = 0
  public private(set) var registeredCategoryCount = 0
  public private(set) var isWorking = false
  public private(set) var lastResult = "Notifications not checked yet."
  public private(set) var lastResponse: HarnessMonitorNotificationResponseSnapshot?
  public private(set) var settingsOpenRequestID = 0

  @ObservationIgnored private let center: UNUserNotificationCenter
  @ObservationIgnored private let assetWriter: HarnessMonitorNotificationAssetWriting
  @ObservationIgnored private var isActivated = false

  public init(
    center: UNUserNotificationCenter = .current(),
    assetWriter: HarnessMonitorNotificationAssetWriting = HarnessMonitorNotificationAssetWriter()
  ) {
    self.center = center
    self.assetWriter = assetWriter
    super.init()
  }

  public static func preview() -> HarnessMonitorUserNotificationController {
    let controller = HarnessMonitorUserNotificationController()
    controller.settingsSnapshot = .preview
    controller.pendingRequestCount = 2
    controller.deliveredNotificationCount = 4
    controller.registeredCategoryCount = HarnessMonitorNotificationRequestFactory.categories().count
    controller.lastResult = "Preview notification controls are ready."
    return controller
  }

  public func activate() {
    guard !isActivated else {
      return
    }
    isActivated = true
    center.delegate = self
    registerCategories()
    Task { await refreshStatus() }
  }

  public func applyPreset(_ preset: HarnessMonitorNotificationPreset) {
    draft = preset.draft
    lastResult = "Loaded \(preset.title) preset."
  }

  public func requestAuthorization(
    profile: HarnessMonitorNotificationAuthorizationProfile
  ) async {
    await performNotificationOperation {
      do {
        let granted = try await center.requestAuthorization(options: profile.options)
        if granted {
          lastResult = "Notification authorization granted."
        } else {
          lastResult = "Authorization was not granted."
        }
        await refreshStatus()
      } catch {
        lastResult = "Authorization failed: \(error.localizedDescription)"
      }
    }
  }

  public func refreshStatus() async {
    let settings = await center.notificationSettings()
    settingsSnapshot = HarnessMonitorNotificationSettingsSnapshot(settings: settings)
    pendingRequestCount = await center.pendingNotificationRequests().count
    deliveredNotificationCount = await center.deliveredNotifications().count
    registeredCategoryCount = await center.notificationCategories().count
  }

  public func deliverDraft() async {
    await performNotificationOperation {
      do {
        registerCategories()
        let request = try await HarnessMonitorNotificationRequestFactory.makeRequest(
          from: draft,
          assetWriter: assetWriter
        )
        try await center.add(request)
        lastResult = "Scheduled notification \(request.identifier)."
        await refreshStatus()
      } catch {
        lastResult = "Scheduling failed: \(error.localizedDescription)"
      }
    }
  }

  public func removeAllPendingRequests() async {
    center.removeAllPendingNotificationRequests()
    lastResult = "Removed pending notification requests."
    await refreshStatus()
  }

  public func removeAllDeliveredNotifications() async {
    center.removeAllDeliveredNotifications()
    lastResult = "Removed delivered notifications."
    await refreshStatus()
  }

  public func resetBadge() async {
    do {
      try await center.setBadgeCount(0)
      lastResult = "Reset the app badge."
      await refreshStatus()
    } catch {
      lastResult = "Badge reset failed: \(error.localizedDescription)"
    }
  }

  nonisolated public func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .list, .sound, .badge]
  }

  nonisolated public func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    let snapshot = HarnessMonitorNotificationResponseSnapshot(response: response)
    await MainActor.run {
      lastResponse = snapshot
      lastResult = "Handled notification action \(snapshot.actionIdentifier)."
    }
  }

  nonisolated public func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    openSettingsFor notification: UNNotification?
  ) {
    Task { @MainActor in
      settingsOpenRequestID += 1
      lastResult = "Opening notification settings."
    }
  }

  private func registerCategories() {
    center.setNotificationCategories(HarnessMonitorNotificationRequestFactory.categories())
    registeredCategoryCount = HarnessMonitorNotificationRequestFactory.categories().count
  }

  private func performNotificationOperation(_ operation: @MainActor () async -> Void) async {
    guard !isWorking else {
      return
    }
    isWorking = true
    defer { isWorking = false }
    await operation()
  }
}

extension HarnessMonitorNotificationSettingsSnapshot {
  public init(settings: UNNotificationSettings) {
    self.authorizationStatus = Self.label(for: settings.authorizationStatus)
    self.alertSetting = Self.label(for: settings.alertSetting)
    self.soundSetting = Self.label(for: settings.soundSetting)
    self.badgeSetting = Self.label(for: settings.badgeSetting)
    self.notificationCenterSetting = Self.label(for: settings.notificationCenterSetting)
    self.lockScreenSetting = Self.label(for: settings.lockScreenSetting)
    self.alertStyle = Self.label(for: settings.alertStyle)
    self.showPreviews = Self.label(for: settings.showPreviewsSetting)
    self.criticalAlertSetting = Self.label(for: settings.criticalAlertSetting)
    self.timeSensitiveSetting = Self.label(for: settings.timeSensitiveSetting)
    self.scheduledDeliverySetting = Self.label(for: settings.scheduledDeliverySetting)
    self.directMessagesSetting = Self.label(for: settings.directMessagesSetting)
    self.providesAppNotificationSettings = settings.providesAppNotificationSettings
  }

  private static func label(for status: UNAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: "not determined"
    case .denied: "denied"
    case .authorized: "authorized"
    case .provisional: "provisional"
    @unknown default: "unknown"
    }
  }

  private static func label(for setting: UNNotificationSetting) -> String {
    switch setting {
    case .notSupported: "not supported"
    case .disabled: "disabled"
    case .enabled: "enabled"
    @unknown default: "unknown"
    }
  }

  private static func label(for style: UNAlertStyle) -> String {
    switch style {
    case .none: "none"
    case .banner: "banner"
    case .alert: "alert"
    @unknown default: "unknown"
    }
  }

  private static func label(for setting: UNShowPreviewsSetting) -> String {
    switch setting {
    case .always: "always"
    case .whenAuthenticated: "when authenticated"
    case .never: "never"
    @unknown default: "unknown"
    }
  }
}
