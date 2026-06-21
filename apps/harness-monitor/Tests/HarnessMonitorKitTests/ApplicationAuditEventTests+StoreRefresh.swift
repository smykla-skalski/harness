import Foundation
import SwiftData
import Testing

@testable import HarnessMonitorKit

extension ApplicationAuditEventTests {
  @MainActor
  @Test("Store refresh imports stored review action history into visible Audit rows")
  func storeRefreshBackfillsGithubAuditRows() async throws {
    let defaults = UserDefaults.standard
    let previousValue = defaults.string(forKey: reviewActionBackfillStorageKey)
    defer {
      if let previousValue {
        defaults.set(previousValue, forKey: reviewActionBackfillStorageKey)
      } else {
        defaults.removeObject(forKey: reviewActionBackfillStorageKey)
      }
    }

    let recordedAt = try #require(
      HarnessMonitorAuditEvent.parseDate("2026-06-01T12:45:00.000Z")
    )
    let storage = [
      "PR_kwDOExample": DashboardReviewActionAuditBackfillEntry(
        id: "action-visible",
        title: "Merging",
        summary: "Merged kong/kuma#12",
        outcome: .success,
        messages: ["Merge applied"],
        recordedAt: recordedAt
      )
    ]
    let encoded = try JSONEncoder().encode(storage)
    let storedValue = try #require(String(bytes: encoded, encoding: .utf8))
    defaults.set(
      storedValue,
      forKey: reviewActionBackfillStorageKey
    )

    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())

    await store.refreshApplicationAudit(limit: 10)

    let event = try #require(
      store.contentUI.dashboard.auditEvents.first {
        $0.id == "github-review-action:PR_kwDOExample:action-visible"
      }
    )
    #expect(event.source == "github")
    #expect(event.category == "githubMutation")
    #expect(event.kind == "reviews.merge")
    #expect(event.subject == "PR_kwDOExample")
  }

  @MainActor
  @Test("Store refresh merges backfill under newer live audit rows")
  func storeRefreshMergesBackfillUnderNewerLiveAuditRows() async throws {
    let defaults = UserDefaults.standard
    let previousValue = defaults.string(forKey: reviewActionBackfillStorageKey)
    defer {
      if let previousValue {
        defaults.set(previousValue, forKey: reviewActionBackfillStorageKey)
      } else {
        defaults.removeObject(forKey: reviewActionBackfillStorageKey)
      }
    }

    let backfillDate = try #require(
      HarnessMonitorAuditEvent.parseDate("2026-06-01T12:45:00.000Z")
    )
    let storage = [
      "PR_kwDOExample": DashboardReviewActionAuditBackfillEntry(
        id: "action-merge-under-live",
        title: "Merging",
        summary: "Merged kong/kuma#12",
        outcome: .success,
        messages: ["Merge applied"],
        recordedAt: backfillDate
      )
    ]
    let encoded = try JSONEncoder().encode(storage)
    let storedValue = try #require(String(bytes: encoded, encoding: .utf8))
    defaults.set(storedValue, forKey: reviewActionBackfillStorageKey)

    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let liveDate = try #require(
      HarnessMonitorAuditEvent.parseDate("2026-06-01T13:00:00.000Z")
    )
    let liveEvent = HarnessMonitorAuditEvent(
      id: "live-newer",
      recordedAt: liveDate,
      source: "daemon",
      category: "lifecycle",
      kind: "daemon.started",
      severity: "info",
      outcome: "success",
      title: "Daemon started",
      summary: "Live daemon audit event"
    )
    store.applyApplicationAuditEvent(liveEvent)

    await store.refreshApplicationAudit(limit: 10)

    let events = store.contentUI.dashboard.auditEvents
    #expect(events.first?.id == "live-newer")
    #expect(
      events.contains {
        $0.id == "github-review-action:PR_kwDOExample:action-merge-under-live"
      })
  }

  @MainActor
  @Test("Store refresh pages stored GitHub review actions into Audit rows")
  func storeRefreshPagesStoredGithubAuditBackfillRows() async throws {
    let defaults = UserDefaults.standard
    let previousValue = defaults.string(forKey: reviewActionBackfillStorageKey)
    defer {
      if let previousValue {
        defaults.set(previousValue, forKey: reviewActionBackfillStorageKey)
      } else {
        defaults.removeObject(forKey: reviewActionBackfillStorageKey)
      }
    }

    let baseDate = try #require(
      HarnessMonitorAuditEvent.parseDate("2026-06-01T12:00:00.000Z")
    )
    let storage = Dictionary(
      uniqueKeysWithValues: (0..<55).map { index in
        (
          "PR_kwDOExample_\(index)",
          DashboardReviewActionAuditBackfillEntry(
            id: "action-\(index)",
            title: index.isMultiple(of: 2) ? "Approving" : "Merging",
            summary: "Updated kong/kuma#\(index)",
            outcome: .success,
            messages: ["GitHub mutation \(index)"],
            recordedAt: baseDate.addingTimeInterval(TimeInterval(index))
          )
        )
      }
    )
    let encoded = try JSONEncoder().encode(storage)
    let storedValue = try #require(String(bytes: encoded, encoding: .utf8))
    defaults.set(storedValue, forKey: reviewActionBackfillStorageKey)

    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let notificationBaseDate = try #require(
      HarnessMonitorAuditEvent.parseDate("2026-06-01T13:00:00.000Z")
    )
    store.notificationHistoryEntries = (0..<45).map { index in
      NotificationHistoryEntry(
        id: "notification-\(index)",
        recordedAt: notificationBaseDate.addingTimeInterval(TimeInterval(index)),
        updatedAt: notificationBaseDate.addingTimeInterval(TimeInterval(index)),
        source: .toast,
        severity: .success,
        status: .dismissed,
        statusText: "Dismissed",
        title: "Notification \(index)",
        message: "Notification audit row \(index)"
      )
    }

    await store.refreshApplicationAudit(limit: 40)

    #expect(store.contentUI.dashboard.auditEvents.count == 40)
    #expect(store.contentUI.dashboard.auditHasOlder)
    #expect(store.contentUI.dashboard.auditEvents.first?.source == "notifications")
    #expect(
      !store.contentUI.dashboard.auditEvents.contains {
        $0.source == "github"
      })

    await store.refreshApplicationAudit(limit: 80)

    #expect(store.contentUI.dashboard.auditEvents.count == 80)
    #expect(store.contentUI.dashboard.auditHasOlder)
    #expect(
      store.contentUI.dashboard.auditEvents.contains {
        $0.id == "github-review-action:PR_kwDOExample_54:action-54"
      }
    )
    #expect(
      !store.contentUI.dashboard.auditEvents.contains {
        $0.id == "github-review-action:PR_kwDOExample_0:action-0"
      })

    await store.refreshApplicationAudit(limit: 120)

    #expect(store.contentUI.dashboard.auditEvents.count == 100)
    #expect(!store.contentUI.dashboard.auditHasOlder)
    #expect(
      store.contentUI.dashboard.auditEvents.contains {
        $0.id == "github-review-action:PR_kwDOExample_0:action-0"
      })
  }

}
