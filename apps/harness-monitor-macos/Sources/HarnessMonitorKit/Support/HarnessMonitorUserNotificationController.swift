import Foundation
import Observation
import UserNotifications

public protocol HarnessMonitorUserNotificationCenter: AnyObject {
  var delegate: UNUserNotificationCenterDelegate? { get set }

  func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
  func notificationSettings() async -> UNNotificationSettings
  func pendingNotificationRequests() async -> [UNNotificationRequest]
  func deliveredNotifications() async -> [UNNotification]
  func notificationCategories() async -> Set<UNNotificationCategory>
  func add(_ request: UNNotificationRequest) async throws
  func removeAllPendingNotificationRequests()
  func removeAllDeliveredNotifications()
  func setBadgeCount(_ newBadgeCount: Int) async throws
  func setNotificationCategories(_ categories: Set<UNNotificationCategory>)
}

extension UNUserNotificationCenter: HarnessMonitorUserNotificationCenter {}

private final class HarnessMonitorUserNotificationCenterBox: @unchecked Sendable {
  let base: any HarnessMonitorUserNotificationCenter

  init(_ base: any HarnessMonitorUserNotificationCenter) {
    self.base = base
  }
}

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
  public private(set) var appBadgeCount = 0
  public private(set) var isWorking = false
  public private(set) var lastResult = "Notifications not checked yet."
  public private(set) var lastResponse: HarnessMonitorNotificationResponseSnapshot?
  public private(set) var settingsOpenRequestID = 0

  /// Last decision id requested by a supervisor notification tap. The scene-support layer
  /// observes this property and calls `openWindow(id: .decisions)` with the selected decision.
  /// The value is rewritten on every `Open` tap - even when the new id equals the previous one -
  /// so observers see each tap as a fresh event (the scene view reads the value once per change
  /// of `@Bindable`/`@Observable` tracking).
  public private(set) var decisionRequestedID: String?

  /// Bumped on every supervisor decision tap that publishes `decisionRequestedID`. Observers
  /// key off this counter to distinguish consecutive taps that resolve to the same decision id.
  public private(set) var decisionRequestTick: Int = 0

  public typealias DecisionResolveHandler = @Sendable (String, DecisionOutcome) async -> Void

  @ObservationIgnored private let centerBox: HarnessMonitorUserNotificationCenterBox
  @ObservationIgnored private let assetWriter: HarnessMonitorNotificationAssetWriting
  @ObservationIgnored private var isActivated = false
  @ObservationIgnored private var resolveHandler: DecisionResolveHandler?

  public init(
    center: any HarnessMonitorUserNotificationCenter = UNUserNotificationCenter.current(),
    assetWriter: HarnessMonitorNotificationAssetWriting = HarnessMonitorNotificationAssetWriter()
  ) {
    centerBox = HarnessMonitorUserNotificationCenterBox(center)
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
    centerBox.base.delegate = self
    registerCategories()
    Task { await refreshStatus() }
  }

  /// Attaches the supervisor `DecisionStore` so notification action handlers can mutate
  /// decisions without going through the Decisions window. `Acknowledge` maps to
  /// `DecisionStore.dismiss(id:)` because the notification action is a lightweight dismissal,
  /// not an in-app suggested-action resolution.
  public func attachDecisionStore(_ store: DecisionStore) {
    attachResolveHandler { id, outcome in
      _ = outcome
      do {
        try await store.dismiss(id: id)
      } catch {
        // Swallow resolve errors here - the notification tap handler logs via `lastResult`
        // and the decision stays visible in the Decisions window for manual resolution.
      }
    }
  }

  /// Installs a closure that handles supervisor decision resolution triggered from outside the
  /// Decisions window (for example, the `Acknowledge` notification action). The closure is
  /// `@Sendable` and called from a detached task.
  public func attachResolveHandler(_ handler: @escaping DecisionResolveHandler) {
    resolveHandler = handler
  }

  /// Schedules a supervisor decision notification for the given severity and decision id.
  /// Registers the supervisor categories on first call so action icons and titles match the
  /// category lookup in Notification Center.
  public func deliverSupervisorDecision(
    severity: DecisionSeverity,
    summary: String,
    decisionID: String
  ) async {
    await performNotificationOperation {
      let preferences = SupervisorNotificationPreferences.load()
      guard preferences.allowsAnyDelivery(for: severity) else {
        lastResult = "Supervisor notification suppressed by preferences."
        return
      }
      do {
        registerCategories()
        let request = try await HarnessMonitorNotificationRequestFactory.makeSupervisorRequest(
          severity: severity,
          summary: summary,
          decisionID: decisionID
        )
        try await centerBox.base.add(request)
        lastResult = "Scheduled supervisor decision \(decisionID)."
        await refreshStatus()
      } catch {
        lastResult = "Scheduling supervisor decision failed: \(error.localizedDescription)"
      }
    }
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
        let granted = try await centerBox.base.requestAuthorization(options: profile.options)
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
    let settings = await centerBox.base.notificationSettings()
    settingsSnapshot = HarnessMonitorNotificationSettingsSnapshot(settings: settings)
    pendingRequestCount = await centerBox.base.pendingNotificationRequests().count
    deliveredNotificationCount = await centerBox.base.deliveredNotifications().count
    registeredCategoryCount = await centerBox.base.notificationCategories().count
  }

  public func deliverDraft() async {
    await performNotificationOperation {
      do {
        registerCategories()
        let request = try await HarnessMonitorNotificationRequestFactory.makeRequest(
          from: draft,
          assetWriter: assetWriter
        )
        try await centerBox.base.add(request)
        lastResult = "Scheduled notification \(request.identifier)."
        await refreshStatus()
      } catch {
        lastResult = "Scheduling failed: \(error.localizedDescription)"
      }
    }
  }

  public func removeAllPendingRequests() async {
    centerBox.base.removeAllPendingNotificationRequests()
    lastResult = "Removed pending notification requests."
    await refreshStatus()
  }

  public func removeAllDeliveredNotifications() async {
    centerBox.base.removeAllDeliveredNotifications()
    lastResult = "Removed delivered notifications."
    await refreshStatus()
  }

  public func syncAppBadgeCount(_ nextCount: Int) async {
    let normalizedCount = max(0, nextCount)
    guard normalizedCount != appBadgeCount else {
      return
    }

    do {
      try await centerBox.base.setBadgeCount(normalizedCount)
      appBadgeCount = normalizedCount
    } catch {
      lastResult = "Badge update failed: \(error.localizedDescription)"
    }
  }

  public func resetBadge() async {
    await syncAppBadgeCount(0)
  }

  nonisolated public func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    let userInfo = notification.request.content.userInfo
    guard let rawSeverity = userInfo[HarnessMonitorSupervisorNotificationID.severityKey] as? String,
      let severity = DecisionSeverity(rawValue: rawSeverity)
    else {
      return [.banner, .list, .sound, .badge]
    }
    return SupervisorNotificationPreferences.load().foregroundPresentationOptions(for: severity)
  }

  nonisolated public func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    let snapshot = HarnessMonitorNotificationResponseSnapshot(response: response)
    let userInfo = response.notification.request.content.userInfo
    let decisionID = Self.decisionID(from: userInfo)
    let actionIdentifier = response.actionIdentifier
    await MainActor.run {
      handleNotificationResponse(
        snapshot: snapshot,
        actionIdentifier: actionIdentifier,
        decisionID: decisionID
      )
    }
  }

  func handleNotificationResponseForTesting(_ response: UNNotificationResponse) {
    let snapshot = HarnessMonitorNotificationResponseSnapshot(response: response)
    let decisionID = Self.decisionID(from: response.notification.request.content.userInfo)
    handleNotificationResponse(
      snapshot: snapshot,
      actionIdentifier: response.actionIdentifier,
      decisionID: decisionID
    )
  }

  nonisolated private static func decisionID(from userInfo: [AnyHashable: Any]) -> String? {
    userInfo[HarnessMonitorSupervisorNotificationID.decisionIDKey] as? String
  }

  private func routeSupervisorAction(actionIdentifier: String, decisionID: String?) {
    guard let decisionID else {
      return
    }
    switch actionIdentifier {
    case HarnessMonitorNotificationActionID.open,
      UNNotificationDefaultActionIdentifier:
      publishDecisionRequest(decisionID: decisionID)
    case HarnessMonitorNotificationActionID.acknowledge:
      dismissDecision(decisionID: decisionID)
    case UNNotificationDismissActionIdentifier:
      // User swiped the notification away; leave the decision untouched so the Decisions window
      // still surfaces it.
      break
    default:
      // Rule-specific actions route through the Decisions window once opened.
      publishDecisionRequest(decisionID: decisionID)
    }
  }

  private func publishDecisionRequest(decisionID: String) {
    decisionRequestedID = decisionID
    decisionRequestTick &+= 1
  }

  private func dismissDecision(decisionID: String) {
    guard let handler = resolveHandler else {
      return
    }
    let outcome = DecisionOutcome(
      chosenActionID: HarnessMonitorNotificationActionID.acknowledge,
      note: "Acknowledged from notification"
    )
    Task { @Sendable in
      await handler(decisionID, outcome)
    }
  }

  private func handleNotificationResponse(
    snapshot: HarnessMonitorNotificationResponseSnapshot,
    actionIdentifier: String,
    decisionID: String?
  ) {
    lastResponse = snapshot
    lastResult = "Handled notification action \(snapshot.actionIdentifier)."
    routeSupervisorAction(actionIdentifier: actionIdentifier, decisionID: decisionID)
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
    centerBox.base.setNotificationCategories(HarnessMonitorNotificationRequestFactory.categories())
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
