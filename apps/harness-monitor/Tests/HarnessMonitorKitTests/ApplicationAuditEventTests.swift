import Foundation
import SwiftData
import Testing

@testable import HarnessMonitorKit

@Suite("Application audit events", .serialized)
struct ApplicationAuditEventTests {
  private let reviewActionBackfillStorageKey = "dashboard.reviews.recent-actions"

  @Test("Audit request and response match daemon snake-case protocol")
  func auditRequestResponseProtocolCoding() throws {
    let request = HarnessMonitorAuditEventsRequest(
      limit: 25,
      before: "2026-06-01T10:00:00.000Z|event-2",
      dateRange: HarnessMonitorAuditDateRange(
        start: "2026-06-01T00:00:00.000Z",
        end: "2026-06-02T00:00:00.000Z"
      ),
      sources: ["github"],
      categories: ["githubMutation"],
      severities: ["error"],
      outcomes: ["failure"],
      actionKeys: ["reviews.merge"],
      subject: "kong/kuma#12",
      searchText: "conflict"
    )
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let encodedRequest = try JSONSerialization.jsonObject(
      with: encoder.encode(request)
    )
    let requestObject = try #require(encodedRequest as? [String: Any])

    #expect(requestObject["date_range"] != nil)
    #expect(requestObject["action_keys"] as? [String] == ["reviews.merge"])
    #expect(requestObject["search_text"] as? String == "conflict")

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let response = try decoder.decode(
      HarnessMonitorAuditEventsResponse.self,
      from: Data(
        #"""
        {
          "events": [
            {
              "id": "event-2",
              "recorded_at": "2026-06-01T10:00:00.000Z",
              "source": "github",
              "category": "githubMutation",
              "kind": "reviews.merge",
              "severity": "error",
              "outcome": "failure",
              "title": "Merge failed",
              "summary": "Conflict blocked merge"
            }
          ],
          "next_cursor": "2026-06-01T10:00:00.000Z|event-2",
          "has_older": true
        }
        """#.utf8
      )
    )

    #expect(response.events.map(\.id) == ["event-2"])
    #expect(response.nextCursor == "2026-06-01T10:00:00.000Z|event-2")
    #expect(response.hasOlder)
  }

  @Test("Daemon audit event JSON decodes from snake case and re-encodes for storage")
  func daemonAuditEventCodableRoundTripsProtocolFields() throws {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let data = Data(
      #"""
      {
        "id": "audit-1",
        "recorded_at": "2026-06-01T10:00:00.000Z",
        "source": "github",
        "category": "githubMutation",
        "kind": "reviews.approve",
        "severity": "info",
        "outcome": "success",
        "title": "Approve pull request",
        "summary": "Approve pull request succeeded",
        "subject": "kong/kuma#12",
        "actor": "Harness Monitor",
        "correlation_id": "corr-1",
        "action_key": "reviews.approve",
        "payload_json": { "token": "ghp_secret", "count": 1 },
        "legacy_message": "legacy row",
        "related_urls": ["https://github.com/kong/kuma/pull/12"]
      }
      """#.utf8
    )

    let event = try decoder.decode(HarnessMonitorAuditEvent.self, from: data)

    #expect(event.id == "audit-1")
    #expect(event.recordedAt == HarnessMonitorAuditEvent.parseDate("2026-06-01T10:00:00.000Z"))
    #expect(event.correlationID == "corr-1")
    #expect(event.actionKey == "reviews.approve")
    #expect(event.relatedURLs == ["https://github.com/kong/kuma/pull/12"])
    #expect(event.payloadJSONString()?.contains("ghp_secret") == false)

    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event))
    let object = try #require(encoded as? [String: Any])
    #expect(object["recordedAt"] as? String == "2026-06-01T10:00:00.000Z")
    #expect(object["correlationId"] as? String == "corr-1")
    #expect(object["payloadJson"] != nil)
    #expect(object["relatedUrls"] != nil)
  }

  @Test("Audit event clipboard JSON contains the complete event")
  func auditEventClipboardJSONStringContainsCompleteEvent() throws {
    let recordedAt = try #require(
      HarnessMonitorAuditEvent.parseDate("2026-06-01T10:00:00.000Z")
    )
    let event = HarnessMonitorAuditEvent(
      id: "audit-copy-1",
      recordedAt: recordedAt,
      source: "github",
      category: "githubMutation",
      kind: "reviews.approve",
      severity: "info",
      outcome: "success",
      title: "Approve pull request",
      summary: "Approve pull request succeeded",
      subject: "kong/kuma#12",
      actor: "Harness Monitor",
      correlationID: "corr-copy-1",
      actionKey: "reviews.approve",
      payloadJSON: .object([
        "count": .number(1),
        "message": .string("approved"),
      ]),
      legacyMessage: "legacy audit row",
      relatedURLs: ["https://github.com/kong/kuma/pull/12"]
    )

    let text = try event.clipboardJSONString()
    let decoded = try JSONDecoder().decode(HarnessMonitorAuditEvent.self, from: Data(text.utf8))

    #expect(decoded == event)
    #expect(text.contains("\n"))
    #expect(text.contains(#""payloadJson""#))
    #expect(text.contains(#""relatedUrls""#))
    #expect(text.contains(#""correlationId""#))
  }

  @Test("Notification history rows map into notification-sourced audit rows")
  func notificationHistoryMapsToAuditRow() throws {
    let recordedAt = try #require(
      HarnessMonitorAuditEvent.parseDate("2026-06-01T11:00:00.000Z")
    )
    let entry = NotificationHistoryEntry(
      id: "toast-success",
      recordedAt: recordedAt,
      updatedAt: recordedAt,
      source: .toast,
      severity: .success,
      status: .dismissed,
      statusText: "Dismissed automatically",
      title: "Draft saved",
      message: "Saved supervisor draft",
      repeatCount: 2,
      requestIdentifier: "request-1",
      decisionID: "decision-1"
    )

    let event = HarnessMonitorAuditEvent.notification(entry)

    #expect(event.id == "notification:toast-success")
    #expect(event.notificationEntryID == "toast-success")
    #expect(event.source == "notifications")
    #expect(event.category == "notification")
    #expect(event.kind == "notification.toast")
    #expect(event.severity == "success")
    #expect(event.outcome == "dismissed")
    #expect(event.subject == "decision-1")
    #expect(event.actionKey == "notification.toast")
    let payload = try #require(event.payloadJSONString())
    #expect(payload.contains("repeat_count"))
    #expect(payload.contains("2"))
  }

  @Test("Supervisor rows preserve metadata and redact sensitive payload fields")
  func supervisorRowsRedactPayload() throws {
    let recordedAt = try #require(
      HarnessMonitorAuditEvent.parseDate("2026-06-01T12:00:00.000Z")
    )
    let snapshot = SupervisorEventSnapshot(
      id: "supervisor-1",
      tickID: "tick-1",
      kind: "actionFailed",
      ruleID: "idle-session",
      severityRaw: "critical",
      payloadJSON: #"{"token":"ghp_secret","mode":"closeSession"}"#,
      createdAt: recordedAt
    )

    let event = HarnessMonitorAuditEvent.supervisor(snapshot)

    #expect(event.id == "supervisor:supervisor-1")
    #expect(event.source == "supervisor")
    #expect(event.category == "decision")
    #expect(event.title == "Action Failed")
    #expect(event.outcome == "failure")
    #expect(event.subject == "idle-session")
    #expect(event.correlationID == "tick-1")
    let payload = try #require(event.payloadJSONString())
    #expect(payload.contains("[redacted]"))
    #expect(!payload.contains("ghp_secret"))
  }

  @Test("Stored review action history backfills GitHub audit rows")
  func reviewActionHistoryBackfillsGithubAuditRows() throws {
    let recordedAt = try #require(
      HarnessMonitorAuditEvent.parseDate("2026-06-01T12:30:00.000Z")
    )
    let storage = [
      "PR_kwDOExample": DashboardReviewActionAuditBackfillEntry(
        id: "action-1",
        title: "Approving",
        summary: "Approved kong/kuma#12",
        outcome: .success,
        messages: ["Approval applied"],
        recordedAt: recordedAt
      )
    ]
    let encoded = try JSONEncoder().encode(storage)
    let storedValue = try #require(String(bytes: encoded, encoding: .utf8))

    let events = HarnessMonitorAuditEvent.githubReviewActionBackfillEvents(
      from: storedValue,
      limit: 10
    )
    let event = try #require(events.first)

    #expect(event.id == "github-review-action:PR_kwDOExample:action-1")
    #expect(event.recordedAt == recordedAt)
    #expect(event.source == "github")
    #expect(event.category == "githubMutation")
    #expect(event.kind == "reviews.approve")
    #expect(event.severity == "info")
    #expect(event.outcome == "success")
    #expect(event.subject == "PR_kwDOExample")
    #expect(event.actor == "Harness Monitor")
    #expect(event.actionKey == "reviews.approve")
    #expect(event.legacyMessage?.contains("Approval applied") == true)
    let payload = try #require(event.payloadJSONString())
    #expect(payload.contains("legacy_pull_request_id"))
    #expect(payload.contains("PR_kwDOExample"))
  }

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
