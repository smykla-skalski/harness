import Foundation

private let dashboardReviewRecentActionsAuditBackfillStorageKey = "dashboard.reviews.recent-actions"

extension HarnessMonitorStore {
  public func refreshApplicationAudit(limit: Int = 500) async {
    let sourceEvents = await applicationAuditBackfillEvents(limit: limit)
    let mergedEvents = HarnessMonitorAuditEvent.merged(sourceEvents)

    guard let userDataService, persistenceError == nil else {
      applicationAuditEvents = Array(mergedEvents.prefix(limit))
      return
    }

    do {
      try await userDataService.upsertAuditEvents(mergedEvents)
      applicationAuditEvents = try await userDataService.loadAuditEvents(limit: limit)
    } catch {
      applicationAuditEvents = Array(mergedEvents.prefix(limit))
      recordPersistenceFailure(
        action: "Audit events could not be loaded",
        underlyingError: error
      )
    }
  }

  func mirrorNotificationHistoryIntoAudit(_ entry: NotificationHistoryEntry) async {
    let event = HarnessMonitorAuditEvent.notification(entry)
    if let userDataService, persistenceError == nil {
      do {
        try await userDataService.upsertAuditEvents([event])
      } catch {
        recordPersistenceFailure(
          action: "Notification audit event could not be saved",
          underlyingError: error
        )
      }
    }
    applicationAuditEvents = HarnessMonitorAuditEvent.merged(applicationAuditEvents + [event])
  }

  private func applicationAuditBackfillEvents(limit: Int) async -> [HarnessMonitorAuditEvent] {
    var events = notificationHistoryEntries.map(HarnessMonitorAuditEvent.notification)
    events.append(contentsOf: loadDashboardReviewActionAuditBackfillEvents(limit: min(limit, 80)))
    let supervisorEvents = await loadSupervisorAuditEventSnapshots(limit: min(limit, 256))
    events.append(contentsOf: supervisorEvents.map(HarnessMonitorAuditEvent.supervisor))
    if let typedDaemonEvents = await loadTypedDaemonAuditEvents(limit: min(limit, 300)) {
      events.append(contentsOf: typedDaemonEvents)
    }
    let recentDaemonEvents =
      diagnostics?.recentEvents
      ?? daemonStatus?.diagnostics.lastEvent.map { [$0] }
    if let recentDaemonEvents {
      events.append(contentsOf: recentDaemonEvents.map(HarnessMonitorAuditEvent.legacyDaemonLog))
    }
    return events
  }

  private func loadDashboardReviewActionAuditBackfillEvents(
    limit: Int
  ) -> [HarnessMonitorAuditEvent] {
    guard
      let storedValue = UserDefaults.standard.string(
        forKey: dashboardReviewRecentActionsAuditBackfillStorageKey
      ),
      !storedValue.isEmpty
    else {
      return []
    }
    return HarnessMonitorAuditEvent.githubReviewActionBackfillEvents(
      from: storedValue,
      limit: limit
    )
  }

  private func loadTypedDaemonAuditEvents(limit: Int) async -> [HarnessMonitorAuditEvent]? {
    guard let client else { return nil }
    do {
      let response = try await client.auditEvents(
        request: HarnessMonitorAuditEventsRequest(limit: limit)
      )
      return response.events
    } catch {
      HarnessMonitorLogger.store.debug(
        "typed audit event refresh failed: \(String(describing: error), privacy: .public)"
      )
      return nil
    }
  }
}
