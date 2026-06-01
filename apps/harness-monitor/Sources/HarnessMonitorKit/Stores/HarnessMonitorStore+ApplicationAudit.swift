import Foundation

private let dashboardReviewRecentActionsAuditBackfillStorageKey = "dashboard.reviews.recent-actions"
private let applicationAuditInMemoryLimit = 1_000
private let applicationAuditDaemonPageLimit = 500

private struct ApplicationAuditBackfillPage {
  let events: [HarnessMonitorAuditEvent]
  let hasOlder: Bool
}

extension HarnessMonitorStore {
  public func refreshApplicationAudit(limit: Int = 500) async {
    let resolvedLimit = min(max(limit, 1), applicationAuditInMemoryLimit)
    let sourcePage = await applicationAuditBackfillPage(limit: resolvedLimit)
    let mergedEvents = boundedApplicationAuditEvents(sourcePage.events, limit: resolvedLimit)
    let sourceHasOlder =
      resolvedLimit < applicationAuditInMemoryLimit
      && (sourcePage.hasOlder || sourcePage.events.count > resolvedLimit)

    guard let userDataService, persistenceError == nil else {
      applicationAuditEvents = mergedEvents
      applicationAuditHasOlder = sourceHasOlder
      return
    }

    do {
      try await userDataService.upsertAuditEvents(
        boundedApplicationAuditEvents(sourcePage.events)
      )
      let cachePage = try await userDataService.loadAuditEventPage(limit: resolvedLimit)
      applicationAuditEvents = cachePage.events
      applicationAuditHasOlder = cachePage.hasOlder || sourceHasOlder
    } catch {
      applicationAuditEvents = mergedEvents
      applicationAuditHasOlder = sourceHasOlder
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

  private func applicationAuditBackfillPage(limit: Int) async -> ApplicationAuditBackfillPage {
    let backfillLimit = min(applicationAuditInMemoryLimit, max(limit, 80))
    var events = notificationHistoryEntries.map(HarnessMonitorAuditEvent.notification)
    events.append(
      contentsOf: loadDashboardReviewActionAuditBackfillEvents(limit: min(backfillLimit, 80))
    )
    let supervisorEvents = await loadSupervisorAuditEventSnapshots(limit: min(backfillLimit, 256))
    events.append(contentsOf: supervisorEvents.map(HarnessMonitorAuditEvent.supervisor))
    var hasOlder = events.count > limit
    if let typedDaemonPage = await loadTypedDaemonAuditEvents(limit: backfillLimit) {
      events.append(contentsOf: typedDaemonPage.events)
      hasOlder = hasOlder || typedDaemonPage.hasOlder
    }
    let recentDaemonEvents =
      diagnostics?.recentEvents
      ?? daemonStatus?.diagnostics.lastEvent.map { [$0] }
    if let recentDaemonEvents {
      events.append(contentsOf: recentDaemonEvents.map(HarnessMonitorAuditEvent.legacyDaemonLog))
    }
    return ApplicationAuditBackfillPage(events: events, hasOlder: hasOlder || events.count > limit)
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

  private func loadTypedDaemonAuditEvents(limit: Int) async -> HarnessMonitorAuditEventsResponse? {
    guard let client else { return nil }
    do {
      var events: [HarnessMonitorAuditEvent] = []
      var nextCursor: String?
      var hasOlder = false
      var before: String?
      var remaining = min(max(limit, 1), applicationAuditInMemoryLimit)
      repeat {
        let pageLimit = min(remaining, applicationAuditDaemonPageLimit)
        let response = try await client.auditEvents(
          request: HarnessMonitorAuditEventsRequest(limit: pageLimit, before: before)
        )
        events.append(contentsOf: response.events)
        nextCursor = response.nextCursor
        hasOlder = response.hasOlder
        remaining -= response.events.count
        guard response.hasOlder, let cursor = response.nextCursor, !response.events.isEmpty else {
          break
        }
        before = cursor
      } while remaining > 0
      return HarnessMonitorAuditEventsResponse(
        events: events,
        nextCursor: nextCursor,
        hasOlder: hasOlder
      )
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
