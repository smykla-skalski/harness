import Foundation
import SwiftData
import Testing

@testable import HarnessMonitorKit

extension ApplicationAuditEventTests {
  @Test("Legacy daemon events remain visible as bounded raw audit rows")
  func legacyDaemonRowsMapToAuditEvents() {
    let daemonEvent = DaemonAuditEvent(
      recordedAt: "2026-06-01T13:00:00Z",
      level: "warn",
      message: "bridge stalled"
    )

    let event = HarnessMonitorAuditEvent.legacyDaemonLog(daemonEvent)

    #expect(event.id.hasPrefix("legacy-daemon:"))
    #expect(event.recordedAt == HarnessMonitorAuditEvent.parseDate("2026-06-01T13:00:00Z"))
    #expect(event.source == "daemon")
    #expect(event.category == "legacyDaemonLog")
    #expect(event.severity == "warning")
    #expect(event.outcome == "warning")
    #expect(event.legacyMessage == "bridge stalled")
  }

  @Test("SwiftData audit cache reports whether older rows exist")
  func swiftDataAuditCacheReportsOlderRows() async throws {
    let container = try HarnessMonitorModelContainer.preview()
    let service = UserDataPersistenceService(
      modelContainer: container,
      maxRecentSearches: 10
    )
    let baseDate = try #require(
      HarnessMonitorAuditEvent.parseDate("2026-06-01T00:00:00Z")
    )
    let events = (0..<45).map { index in
      HarnessMonitorAuditEvent(
        id: "audit-\(index)",
        recordedAt: baseDate.addingTimeInterval(TimeInterval(index)),
        source: "daemon",
        category: "lifecycle",
        kind: "daemon.cache_page_test",
        severity: "info",
        outcome: "success",
        title: "Audit cache page test \(index)",
        summary: "Audit cache paging test"
      )
    }

    try await service.upsertAuditEvents(events)

    let firstPage = try await service.loadAuditEventPage(limit: 40)
    #expect(firstPage.events.count == 40)
    #expect(firstPage.hasOlder)
    #expect(firstPage.events.first?.id == "audit-44")
    #expect(!firstPage.events.contains { $0.id == "audit-4" })

    let fullPage = try await service.loadAuditEventPage(limit: 80)
    #expect(fullPage.events.count == 45)
    #expect(!fullPage.hasOlder)
    #expect(fullPage.events.contains { $0.id == "audit-0" })
  }

  @Test("SwiftData audit cache prunes stale rows")
  func swiftDataAuditCachePrunesStaleRows() async throws {
    let container = try HarnessMonitorModelContainer.preview()
    let service = UserDataPersistenceService(
      modelContainer: container,
      maxRecentSearches: 10
    )
    let baseDate = try #require(
      HarnessMonitorAuditEvent.parseDate("2026-06-01T00:00:00Z")
    )
    let events = (0..<1_005).map { index in
      HarnessMonitorAuditEvent(
        id: "audit-\(index)",
        recordedAt: baseDate.addingTimeInterval(TimeInterval(index)),
        source: "daemon",
        category: "lifecycle",
        kind: "daemon.cache_test",
        severity: "info",
        outcome: "success",
        title: "Audit cache test \(index)",
        summary: "Audit cache pruning test"
      )
    }

    try await service.upsertAuditEvents(events)

    let loaded = try await service.loadAuditEvents(limit: 2_000)
    #expect(loaded.count == 1_000)
    #expect(loaded.first?.id == "audit-1004")
    #expect(!loaded.contains { $0.id == "audit-0" })
    #expect(loaded.contains { $0.id == "audit-5" })
  }

  @MainActor
  @Test("Store audit cache hydration keeps newer live rows at top")
  func storeAuditCacheHydrationKeepsNewerLiveRowsAtTop() async throws {
    let container = try HarnessMonitorModelContainer.preview()
    let service = UserDataPersistenceService(
      modelContainer: container,
      maxRecentSearches: 10
    )
    let cachedDate = try #require(
      HarnessMonitorAuditEvent.parseDate("2026-06-01T12:00:00.000Z")
    )
    let cachedEvent = HarnessMonitorAuditEvent(
      id: "cached-older",
      recordedAt: cachedDate,
      source: "github",
      category: "githubMutation",
      kind: "reviews.approve",
      severity: "info",
      outcome: "success",
      title: "Approve pull request",
      summary: "Cached GitHub approval",
      actionKey: "reviews.approve"
    )
    try await service.upsertAuditEvents([cachedEvent])

    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      modelContainer: container
    )
    let liveDate = try #require(
      HarnessMonitorAuditEvent.parseDate("2026-06-01T13:00:00.000Z")
    )
    store.applyApplicationAuditEvent(
      HarnessMonitorAuditEvent(
        id: "live-newer",
        recordedAt: liveDate,
        source: "daemon",
        category: "lifecycle",
        kind: "daemon.started",
        severity: "info",
        outcome: "success",
        title: "Daemon started",
        summary: "Live daemon audit event"
      ))

    await store.hydrateApplicationAuditCache(limit: 40)

    let visibleIDs = Array(store.contentUI.dashboard.auditEvents.prefix(2)).map(\.id)
    #expect(visibleIDs == ["live-newer", "cached-older"])
  }
}
