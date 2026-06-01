import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Application audit events")
struct ApplicationAuditEventTests {
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
    let storedValue = try #require(String(data: encoded, encoding: .utf8))

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
}
