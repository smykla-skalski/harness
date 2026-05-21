// swiftlint:disable file_length
import Foundation
import Observation
import UserNotifications

@MainActor
@Observable
// swiftlint:disable:next type_body_length attributes
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
  public private(set) var lastResult = "Notifications not checked yet"
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
  @ObservationIgnored private let previewSettingsSnapshot:
    HarnessMonitorNotificationSettingsSnapshot?
  @ObservationIgnored private var isActivated = false
  @ObservationIgnored private var resolveHandler: DecisionResolveHandler?
  @ObservationIgnored private var historyEventSink:
    (@MainActor (NotificationHistorySystemEvent) -> Void)?

  public init(
    center: any HarnessMonitorUserNotificationCenter = UNUserNotificationCenter.current(),
    assetWriter: HarnessMonitorNotificationAssetWriting = HarnessMonitorNotificationAssetWriter(),
    previewSettingsSnapshot: HarnessMonitorNotificationSettingsSnapshot? = nil
  ) {
    centerBox = HarnessMonitorUserNotificationCenterBox(center)
    self.assetWriter = assetWriter
    self.previewSettingsSnapshot = previewSettingsSnapshot
    super.init()
  }

  public static func preview(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> HarnessMonitorUserNotificationController {
    let settingsSnapshot = AcpPermissionUserNotifications.previewSettingsSnapshot(
      environment: environment
    )
    let center = PreviewHarnessMonitorUserNotificationCenter(
      categories: HarnessMonitorNotificationRequestFactory.categories()
    )
    let controller = HarnessMonitorUserNotificationController(
      center: center,
      previewSettingsSnapshot: settingsSnapshot
    )
    controller.settingsSnapshot = settingsSnapshot
    controller.pendingRequestCount = 0
    controller.deliveredNotificationCount = 0
    controller.registeredCategoryCount = HarnessMonitorNotificationRequestFactory.categories().count
    controller.lastResult = "Preview notification controls are ready"
    return controller
  }

  public static func preview(
    environment: HarnessMonitorEnvironment
  ) -> HarnessMonitorUserNotificationController {
    preview(environment: environment.values)
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
  /// decisions without going through the workspace window. `Acknowledge` maps to
  /// `DecisionStore.dismiss(id:)` because the notification action is a lightweight dismissal,
  /// not an in-app suggested-action resolution.
  public func attachDecisionStore(_ store: DecisionStore) {
    attachResolveHandler { id, outcome in
      _ = outcome
      do {
        try await store.dismiss(id: id)
      } catch {
        // Swallow resolve errors here - the notification tap handler logs via `lastResult`
        // and the decision stays visible in the workspace window for manual resolution.
      }
    }
  }

  /// Installs a closure that handles supervisor decision resolution triggered from outside the
  /// workspace window (for example, the `Acknowledge` notification action). The closure is
  /// `@Sendable` and called from a detached task.
  public func attachResolveHandler(_ handler: @escaping DecisionResolveHandler) {
    resolveHandler = handler
  }

  public func detachResolveHandler() {
    resolveHandler = nil
  }

  public func attachHistoryEventSink(
    _ sink: @escaping @MainActor (NotificationHistorySystemEvent) -> Void
  ) {
    historyEventSink = sink
  }

  public func detachHistoryEventSink() {
    historyEventSink = nil
  }

  /// Schedules a supervisor decision notification for the given severity and decision id.
  /// Registers the supervisor categories on first call so action icons and titles match the
  /// category lookup in Notification Center.
  public func deliverSupervisorDecision(
    severity: DecisionSeverity,
    summary: String,
    decisionID: String
  ) async -> Bool {
    await deliverSupervisorNotification(
      descriptor: SupervisorNotificationDescriptor(
        source: .supervisorDecision,
        severity: severity,
        successMessage: "Scheduled supervisor decision \(decisionID)",
        failureMessage: "Scheduling supervisor decision failed",
        actions: decisionActions(decisionID: decisionID)
      )
    ) {
      try await HarnessMonitorNotificationRequestFactory.makeSupervisorRequest(
        severity: severity,
        summary: summary,
        decisionID: decisionID
      )
    }
  }

  public func deliverSupervisorNotice(
    severity: DecisionSeverity,
    summary: String,
    ruleID: String
  ) async -> Bool {
    await deliverSupervisorNotification(
      descriptor: SupervisorNotificationDescriptor(
        source: .supervisorNotice,
        severity: severity,
        successMessage: "Scheduled supervisor notice for \(ruleID)",
        failureMessage: "Scheduling supervisor notice failed",
        actions: []
      )
    ) {
      try await HarnessMonitorNotificationRequestFactory.makeSupervisorNoticeRequest(
        severity: severity,
        summary: summary,
        ruleID: ruleID
      )
    }
  }

  private func deliverSupervisorNotification(
    descriptor: SupervisorNotificationDescriptor,
    makeRequest: () async throws -> UNNotificationRequest
  ) async -> Bool {
    let severity = descriptor.severity
    return await performNotificationOperation {
      let settings = SupervisorNotificationSettings.load()
      guard settings.allowsAnyDelivery(for: severity) else {
        lastResult = "Supervisor notification suppressed by settings"
        return false
      }
      do {
        registerCategories()
        let request = try await makeRequest()
        try await centerBox.base.add(request)
        historyEventSink?(
          .scheduled(
            request: NotificationHistoryRequestSnapshot(request: request),
            source: descriptor.source,
            severity: .init(severity),
            actions: descriptor.actions
          ))
        lastResult = descriptor.successMessage
        await refreshStatus()
        return true
      } catch {
        lastResult = "\(descriptor.failureMessage): \(error.localizedDescription)"
        return false
      }
    } ?? false
  }

  private func decisionActions(decisionID: String) -> [NotificationHistoryAction] {
    [
      NotificationHistoryAction(
        id: "open",
        title: "Open",
        systemImage: "arrow.up.forward.app",
        kind: .openDecision(decisionID: decisionID)
      ),
      NotificationHistoryAction(
        id: "acknowledge",
        title: "Acknowledge",
        systemImage: "checkmark.circle",
        kind: .acknowledgeDecision(decisionID: decisionID)
      ),
    ]
  }

  public func applyPreset(_ preset: HarnessMonitorNotificationPreset) {
    draft = preset.draft
    lastResult = "Loaded \(preset.title) preset"
  }

  public func requestAuthorization(
    profile: HarnessMonitorNotificationAuthorizationProfile
  ) async {
    await performNotificationOperation {
      do {
        let granted = try await centerBox.base.requestAuthorization(options: profile.options)
        if granted {
          lastResult = "Notification authorization granted"
        } else {
          lastResult = "Authorization was not granted"
        }
        await refreshStatus()
      } catch {
        lastResult = "Authorization failed: \(error.localizedDescription)"
      }
    }
  }

  public func refreshStatus() async {
    if let previewSettingsSnapshot {
      settingsSnapshot = previewSettingsSnapshot
      pendingRequestCount = await centerBox.base.pendingNotificationRequests().count
      deliveredNotificationCount = await centerBox.base.deliveredNotifications().count
      registeredCategoryCount = await centerBox.base.notificationCategories().count
      return
    }
    let settings = await centerBox.base.notificationSettings()
    settingsSnapshot = HarnessMonitorNotificationSettingsSnapshot(settings: settings)
    pendingRequestCount = await centerBox.base.pendingNotificationRequests().count
    deliveredNotificationCount = await centerBox.base.deliveredNotifications().count
    registeredCategoryCount = await centerBox.base.notificationCategories().count
  }

  @discardableResult
  public func deliverAcpPermissionRequest(_ attention: AcpPermissionAttentionEvent) async -> Bool {
    if AcpPermissionUserNotifications.authorizationStatus(from: settingsSnapshot) == .unknown {
      await refreshStatus()
    }
    let authorizationStatus = AcpPermissionUserNotifications.authorizationStatus(
      from: settingsSnapshot
    )
    guard authorizationStatus.allowsUserNotificationDelivery else {
      lastResult =
        "ACP permission notification skipped: \(authorizationStatus.rawValue)"
      return false
    }

    var didSchedule = false
    await performNotificationOperation {
      do {
        registerCategories()
        let request = HarnessMonitorNotificationRequestFactory.makeAcpPermissionRequest(
          agentName: attention.agentName,
          decisionID: attention.decisionID
        )
        try await centerBox.base.add(request)
        historyEventSink?(
          .scheduled(
            request: NotificationHistoryRequestSnapshot(request: request),
            source: .acpPermission,
            severity: .attention,
            actions: decisionActions(decisionID: attention.decisionID)
          ))
        didSchedule = true
        lastResult = "Scheduled ACP permission \(attention.batchID)"
        await refreshStatus()
      } catch {
        lastResult = "Scheduling ACP permission failed: \(error.localizedDescription)"
      }
    }
    return didSchedule
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
        historyEventSink?(
          .scheduled(
            request: NotificationHistoryRequestSnapshot(request: request),
            source: .settingsDraft,
            severity: .info,
            actions: []
          ))
        lastResult = "Scheduled notification \(request.identifier)"
        await refreshStatus()
      } catch {
        lastResult = "Scheduling failed: \(error.localizedDescription)"
      }
    }
  }

  public func removeAllPendingRequests() async {
    centerBox.base.removeAllPendingNotificationRequests()
    lastResult = "Removed pending notification requests"
    await refreshStatus()
  }

  public func removeAllDeliveredNotifications() async {
    centerBox.base.removeAllDeliveredNotifications()
    lastResult = "Removed delivered notifications"
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
    return SupervisorNotificationSettings.load().foregroundPresentationOptions(for: severity)
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
      // User swiped the notification away; leave the decision untouched so the workspace window
      // still surfaces it.
      break
    default:
      // Rule-specific actions route through the workspace window once opened.
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
    lastResult = "Handled notification action \(snapshot.actionIdentifier)"
    historyEventSink?(.responded(.init(snapshot: snapshot, decisionID: decisionID)))
    routeSupervisorAction(actionIdentifier: actionIdentifier, decisionID: decisionID)
  }

  nonisolated public func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    openSettingsFor notification: UNNotification?
  ) {
    Task { @MainActor in
      settingsOpenRequestID += 1
      lastResult = "Opening notification settings"
    }
  }

  private func registerCategories() {
    centerBox.base.setNotificationCategories(HarnessMonitorNotificationRequestFactory.categories())
    registeredCategoryCount = HarnessMonitorNotificationRequestFactory.categories().count
  }

  @discardableResult
  public func openDecisionRequest(decisionID: String) -> Bool {
    publishDecisionRequest(decisionID: decisionID)
    return true
  }

  @discardableResult
  public func acknowledgeDecision(decisionID: String) -> Bool {
    guard resolveHandler != nil else {
      return false
    }
    dismissDecision(decisionID: decisionID)
    return true
  }

  private func performNotificationOperation<Result>(
    _ operation: @MainActor () async -> Result
  ) async -> Result? {
    guard !isWorking else {
      return nil
    }
    isWorking = true
    defer { isWorking = false }
    return await operation()
  }
}

private struct SupervisorNotificationDescriptor {
  let source: NotificationHistoryEntry.Source
  let severity: DecisionSeverity
  let successMessage: String
  let failureMessage: String
  let actions: [NotificationHistoryAction]
}
