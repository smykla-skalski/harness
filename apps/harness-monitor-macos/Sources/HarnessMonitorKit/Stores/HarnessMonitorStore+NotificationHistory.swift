import AppKit
import Foundation
import UserNotifications

extension HarnessMonitorStore {
  func configureToastHistoryEvents() {
    toast.onHistoryEvent = { [weak self] event in
      guard let self else { return }
      let feedbackID = event.feedback.id
      if self.isSuppressingNotificationHistoryToast {
        self.suppressedNotificationHistoryToastIDs.insert(feedbackID)
        return
      }
      if self.suppressedNotificationHistoryToastIDs.contains(feedbackID) {
        if case .dismissed = event.kind {
          self.suppressedNotificationHistoryToastIDs.remove(feedbackID)
        }
        return
      }
      Task { @MainActor [weak self] in
        await self?.recordToastHistoryEvent(event)
      }
    }
  }

  func scheduleNotificationHistoryRefresh() {
    guard userDataService != nil else {
      notificationHistoryRuntimeActions.removeAll()
      notificationHistoryEntries = []
      return
    }
    Task { @MainActor [weak self] in
      await self?.refreshNotificationHistory()
    }
  }

  public func refreshNotificationHistory() async {
    guard let userDataService, persistenceError == nil else {
      notificationHistoryRuntimeActions.removeAll()
      notificationHistoryEntries = []
      return
    }

    do {
      _ = try await userDataService.purgeNonRestorableNotificationHistory()
      notificationHistoryRuntimeActions.removeAll()
      notificationHistoryEntries = try await userDataService.loadNotificationHistory()
    } catch {
      notificationHistoryRuntimeActions.removeAll()
      notificationHistoryEntries = []
      recordPersistenceFailure(
        action: "Notification history could not be loaded",
        underlyingError: error
      )
    }
  }

  func handleNotificationHistoryEvent(_ event: NotificationHistorySystemEvent) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      switch event {
      case .scheduled(let request, let source, let severity, let actions):
        await upsertNotificationHistoryEntry(
          NotificationHistoryEntry(
            id: request.identifier,
            recordedAt: request.scheduledAt,
            updatedAt: request.scheduledAt,
            source: source,
            severity: severity,
            status: .delivered,
            statusText: scheduledStatusText(for: source),
            title: request.title.nilIfEmpty,
            subtitle: request.subtitle.nilIfEmpty,
            message: request.body,
            actions: actions,
            categoryIdentifier: request.categoryIdentifier.nilIfEmpty,
            requestIdentifier: request.identifier,
            decisionID: request.userInfo[HarnessMonitorSupervisorNotificationID.decisionIDKey],
            dropsOnRelaunch: false
          ))
      case .responded(let update):
        await applyNotificationHistoryResponse(update)
      }
    }
  }

  @discardableResult
  public func performNotificationHistoryAction(
    entryID: String,
    action: NotificationHistoryAction
  ) async -> Bool {
    switch action.kind {
    case .copy(let text):
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
      if let announcement = action.successAnnouncement {
        AccessibilityNotification.Announcement(announcement).post()
      }
      return true
    case .openDecision(let decisionID):
      guard
        supervisorBindings.notificationController?.openDecisionRequest(decisionID: decisionID)
          == true
      else {
        presentFailureFeedback("Notification actions are unavailable")
        return false
      }
      await mutateNotificationHistory(id: entryID) { entry in
        entry.status = .opened
        entry.statusText = "Opened from Notifications"
        entry.updatedAt = .now
      }
      return true
    case .acknowledgeDecision(let decisionID):
      guard
        supervisorBindings.notificationController?.acknowledgeDecision(decisionID: decisionID)
          == true
      else {
        presentFailureFeedback("Notification actions are unavailable")
        return false
      }
      await mutateNotificationHistory(id: entryID) { entry in
        entry.status = .acknowledged
        entry.statusText = "Acknowledged from Notifications"
        entry.actions = []
        entry.updatedAt = .now
        entry.dropsOnRelaunch = false
      }
      return true
    case .runtimeUndo(let token):
      guard let action = notificationHistoryRuntimeActions[token] else {
        presentFailureFeedback("That undo action is no longer available")
        return false
      }
      await action()
      return true
    }
  }

  func recordToastHistoryEvent(_ event: ToastHistoryEvent) async {
    var actions: [NotificationHistoryAction] = []
    if let primaryAction = event.feedback.primaryAction {
      actions.append(
        NotificationHistoryAction(
          id: "\(event.feedback.id.uuidString)-primary",
          action: primaryAction
        ))
    }
    if event.hasUndoAction {
      let token = "\(event.feedback.id.uuidString)-undo"
      notificationHistoryRuntimeActions[token] = { [weak self] in
        guard let self else { return }
        self.toast.invokeUndo(id: event.feedback.id)
      }
      actions.append(
        NotificationHistoryAction(
          id: token,
          title: "Undo",
          systemImage: "arrow.uturn.backward",
          kind: .runtimeUndo(token: token),
          successAnnouncement: "Undo complete"
        ))
    }

    var entry = NotificationHistoryEntry(
      id: event.feedback.id.uuidString,
      recordedAt: existingNotificationHistoryEntry(id: event.feedback.id.uuidString)?.recordedAt
        ?? event.recordedAt,
      updatedAt: event.recordedAt,
      source: .toast,
      severity: .init(event.feedback.severity),
      status: .active,
      statusText: event.hasUndoAction ? "Undo available" : "Visible in app",
      title: event.feedback.title,
      message: event.feedback.message,
      details: event.feedback.details.map(NotificationHistoryDetails.init),
      actions: actions,
      repeatCount: event.feedback.repeatCount,
      accessibilityIdentifier: event.feedback.accessibilityIdentifier,
      dropsOnRelaunch: actions.contains(where: \.isRuntimeOnly)
    )

    switch event.kind {
    case .presented, .refreshed:
      break
    case .dismissed(let reason):
      entry.status = status(for: reason)
      entry.statusText = statusText(for: reason)
      entry.actions = []
      entry.updatedAt = event.recordedAt
      entry.dropsOnRelaunch = false
    }

    await upsertNotificationHistoryEntry(entry)
  }

  private func applyNotificationHistoryResponse(_ update: NotificationHistoryResponseUpdate) async {
    guard
      let index = notificationHistoryEntries.firstIndex(where: {
        $0.requestIdentifier == update.requestIdentifier || $0.id == update.requestIdentifier
      })
    else {
      return
    }

    var entry = notificationHistoryEntries[index]
    entry.responseActionIdentifier = update.actionIdentifier
    entry.responseText = update.textInput
    entry.updatedAt = update.receivedAt
    switch update.actionIdentifier {
    case HarnessMonitorNotificationActionID.acknowledge:
      entry.status = .acknowledged
      entry.statusText = "Acknowledged in Notification Center"
      entry.actions = []
    case HarnessMonitorNotificationActionID.open, UNNotificationDefaultActionIdentifier:
      entry.status = .opened
      entry.statusText = "Opened in Notification Center"
    case UNNotificationDismissActionIdentifier:
      entry.status = .dismissed
      entry.statusText = "Dismissed in Notification Center"
    case HarnessMonitorNotificationActionID.retry:
      entry.status = .acted
      entry.statusText = "Retry selected"
    case HarnessMonitorNotificationActionID.delete:
      entry.status = .acted
      entry.statusText = "Delete selected"
      entry.actions = []
    case HarnessMonitorNotificationActionID.reply:
      entry.status = .acted
      entry.statusText =
        update.textInput?.isEmpty == false
        ? "Reply sent"
        : "Reply selected"
      entry.actions = []
    default:
      entry.status = .acted
      entry.statusText = "Action completed"
    }
    entry.dropsOnRelaunch = entry.actions.contains(where: \.isRuntimeOnly)
    await upsertNotificationHistoryEntry(entry)
  }

  private func upsertNotificationHistoryEntry(_ entry: NotificationHistoryEntry) async {
    do {
      if let userDataService, persistenceError == nil {
        try await userDataService.upsertNotificationHistory(entry)
      }
      applyNotificationHistoryEntry(entry)
    } catch {
      recordPersistenceFailure(
        action: "Notification history could not be saved",
        underlyingError: error
      )
    }
  }

  private func applyNotificationHistoryEntry(_ entry: NotificationHistoryEntry) {
    syncNotificationRuntimeActions(for: entry)
    if let index = notificationHistoryEntries.firstIndex(where: { $0.id == entry.id }) {
      notificationHistoryEntries[index] = entry
    } else {
      notificationHistoryEntries.append(entry)
    }
    notificationHistoryEntries.sort {
      if $0.recordedAt != $1.recordedAt {
        return $0.recordedAt > $1.recordedAt
      }
      if $0.updatedAt != $1.updatedAt {
        return $0.updatedAt > $1.updatedAt
      }
      return $0.id < $1.id
    }
  }

  private func mutateNotificationHistory(
    id: String,
    _ mutate: (inout NotificationHistoryEntry) -> Void
  ) async {
    guard let index = notificationHistoryEntries.firstIndex(where: { $0.id == id })
    else {
      return
    }
    var entry = notificationHistoryEntries[index]
    mutate(&entry)
    await upsertNotificationHistoryEntry(entry)
  }

  private func syncNotificationRuntimeActions(for entry: NotificationHistoryEntry) {
    let liveTokens = Set(
      entry.actions.compactMap { action -> String? in
        if case .runtimeUndo(let token) = action.kind {
          return token
        }
        return nil
      })
    for action in existingNotificationHistoryEntry(id: entry.id)?.actions ?? [] {
      if case .runtimeUndo(let token) = action.kind, !liveTokens.contains(token) {
        notificationHistoryRuntimeActions.removeValue(forKey: token)
      }
    }
  }

  private func existingNotificationHistoryEntry(id: String) -> NotificationHistoryEntry? {
    notificationHistoryEntries.first { $0.id == id }
  }

  func withNotificationHistoryToastSuppressed(_ operation: () -> Void) {
    let wasSuppressing = isSuppressingNotificationHistoryToast
    isSuppressingNotificationHistoryToast = true
    operation()
    isSuppressingNotificationHistoryToast = wasSuppressing
  }

  private func status(for reason: ToastHistoryEvent.DismissReason)
    -> NotificationHistoryEntry.Status
  {
    switch reason {
    case .manual, .timedOut:
      .dismissed
    case .evicted:
      .evicted
    case .undoInvoked:
      .undone
    }
  }

  private func statusText(for reason: ToastHistoryEvent.DismissReason) -> String {
    switch reason {
    case .manual:
      "Dismissed manually"
    case .timedOut:
      "Dismissed automatically"
    case .evicted:
      "Moved out of the visible stack"
    case .undoInvoked:
      "Undo completed"
    }
  }

  private func scheduledStatusText(for source: NotificationHistoryEntry.Source) -> String {
    switch source {
    case .supervisorDecision, .acpPermission:
      "Awaiting response"
    case .supervisorNotice, .settingsDraft:
      "Scheduled in Notification Center"
    case .toast:
      "Visible in app"
    }
  }
}

extension String {
  fileprivate var nilIfEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
