import Foundation
import UserNotifications

extension HarnessMonitorUserNotificationController {
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

  nonisolated static func decisionID(from userInfo: [AnyHashable: Any]) -> String? {
    userInfo[HarnessMonitorSupervisorNotificationID.decisionIDKey] as? String
  }

  func routeSupervisorAction(actionIdentifier: String, decisionID: String?) {
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

  func publishDecisionRequest(decisionID: String) {
    decisionRequestedID = decisionID
    decisionRequestTick &+= 1
  }

  func dismissDecision(decisionID: String) {
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

  func handleNotificationResponse(
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

  func registerCategories() {
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

  func performNotificationOperation<Result>(
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
