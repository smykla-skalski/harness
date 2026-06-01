import Foundation

private let dashboardReviewRecentActionsAuditBackfillStorageKey = "dashboard.reviews.recent-actions"
private let applicationAuditInMemoryLimit = 1_000

extension HarnessMonitorStore {
  public func refreshApplicationAudit(limit: Int = 500) async {
    let resolvedLimit = min(max(limit, 1), applicationAuditInMemoryLimit)
    let sourceEvents = await applicationAuditBackfillEvents(limit: resolvedLimit)
    let mergedEvents = boundedApplicationAuditEvents(sourceEvents, limit: resolvedLimit)

    guard let userDataService, persistenceError == nil else {
      applicationAuditEvents = mergedEvents
      return
    }

    do {
      try await userDataService.upsertAuditEvents(mergedEvents)
      applicationAuditEvents = try await userDataService.loadAuditEvents(limit: resolvedLimit)
    } catch {
      applicationAuditEvents = mergedEvents
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
    applyApplicationAuditEvent(event)
  }

  func applyApplicationAuditEvent(_ event: HarnessMonitorAuditEvent) {
    applicationAuditEvents = boundedApplicationAuditEvents(applicationAuditEvents + [event])
  }

  func applyApplicationAuditEventFromStream(_ event: HarnessMonitorAuditEvent) async {
    applyApplicationAuditEvent(event)
    guard let userDataService, persistenceError == nil else {
      return
    }
    do {
      try await userDataService.upsertAuditEvents([event])
    } catch {
      let description = RefreshSnapshotErrorFormatting.describeUnderlying(error)
      HarnessMonitorLogger.store.error(
        "live audit event could not be saved: \(description, privacy: .public)"
      )
    }
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

  private func boundedApplicationAuditEvents(
    _ events: [HarnessMonitorAuditEvent],
    limit: Int = applicationAuditInMemoryLimit
  ) -> [HarnessMonitorAuditEvent] {
    Array(HarnessMonitorAuditEvent.merged(events).prefix(limit))
  }
}
