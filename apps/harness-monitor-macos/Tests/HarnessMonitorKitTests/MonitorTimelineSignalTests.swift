import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("Monitor timeline signal tone")
struct MonitorTimelineSignalToneTests {
  // Signal tone dispatch lives on SignalTimelineEventFeature.tone(for:) which reads
  // entry.summary, not entry.kind. SessionTimelineTone.eventTone reads entry.kind and
  // returns .info for all signal_* kinds; the feature overrides it in the builder.
  private let feature = SignalTimelineEventFeature()

  @Test("Signal feature tone dispatches on summary text not kind string")
  func signalFeatureToneDispatchesOnSummaryText() {
    #expect(
      feature.tone(
        for: makeEntry(
          kind: "signal_acknowledged",
          summary: "sig-abc delivered to codex-worker: Accepted"
        )) == .success
    )
    #expect(
      feature.tone(
        for: makeEntry(
          kind: "signal_acknowledged",
          summary: "sig-abc rejected from codex-worker: Rejected"
        )) == .critical
    )
    #expect(
      feature.tone(
        for: makeEntry(
          kind: "signal_acknowledged",
          summary: "sig-abc deferred by codex-worker: Deferred"
        )) == .warning
    )
    #expect(
      feature.tone(
        for: makeEntry(
          kind: "signal_acknowledged",
          summary: "sig-abc expired without acknowledgement: Expired"
        )) == .warning
    )
    #expect(
      feature.tone(
        for: makeEntry(
          kind: "signal_sent",
          summary: "codex-worker sent signal sig-abc: inject_context"
        )) == .info
    )
    #expect(
      feature.tone(
        for: makeEntry(
          kind: "signal_received",
          summary: "codex-worker picked up sig-abc: inject_context"
        )) == .info
    )
  }
}

@MainActor
@Suite("Monitor timeline signal VO label")
struct MonitorTimelineSignalVOLabelTests {
  @Test("Signal VO label uses status verb and excludes internal kind string")
  func signalVOLabelStatusVerbDispatch() throws {
    let entries = [
      makeEntry(
        id: "sig-sent",
        kind: "signal_sent",
        summary: "codex-worker sent signal sig-abc: inject_context",
        payload: .object(["signal_id": .string("sig-abc")])
      ),
      makeEntry(
        id: "sig-received",
        kind: "signal_received",
        summary: "codex-worker picked up sig-abc: inject_context",
        payload: .object(["event": .object(["signal_id": .string("sig-abc")])])
      ),
      makeEntry(
        id: "sig-accepted",
        kind: "signal_acknowledged",
        summary: "sig-abc delivered to codex-worker: Accepted",
        payload: .object(["signal_id": .string("sig-abc")])
      ),
      makeEntry(
        id: "sig-rejected",
        kind: "signal_acknowledged",
        summary: "sig-abc rejected from codex-worker: Rejected",
        payload: .object(["signal_id": .string("sig-abc")])
      ),
      makeEntry(
        id: "sig-deferred",
        kind: "signal_acknowledged",
        summary: "sig-abc deferred by codex-worker: Deferred",
        payload: .object(["signal_id": .string("sig-abc")])
      ),
      makeEntry(
        id: "sig-expired",
        kind: "signal_acknowledged",
        summary: "sig-abc expired without acknowledgement: Expired",
        payload: .object(["signal_id": .string("sig-abc")])
      ),
    ]
    let nodes = SessionTimelineNodeBuilder(sessionID: "session-1", entries: entries, decisions: [])
      .build()
    let rows = SessionTimelineRow.rows(for: nodes, configuration: .default)
    let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })

    let expectations = [
      MonitorTimelineSignalExpectation(
        id: "entry:sig-sent",
        prefix: "Signal Sent",
        containsText: "codex-worker sent signal"
      ),
      MonitorTimelineSignalExpectation(
        id: "entry:sig-received",
        prefix: "Signal Received",
        containsText: "picked up"
      ),
      MonitorTimelineSignalExpectation(
        id: "entry:sig-accepted",
        prefix: "Signal Delivered",
        containsText: "Accepted"
      ),
      MonitorTimelineSignalExpectation(
        id: "entry:sig-rejected",
        prefix: "Signal Rejected",
        containsText: "Rejected"
      ),
      MonitorTimelineSignalExpectation(
        id: "entry:sig-deferred",
        prefix: "Signal Deferred",
        containsText: "Deferred"
      ),
      MonitorTimelineSignalExpectation(
        id: "entry:sig-expired",
        prefix: "Signal Expired",
        containsText: "Expired"
      ),
    ]
    for expectation in expectations {
      let label = try #require(byID[expectation.id]?.accessibilityLabel)
      #expect(label.hasPrefix(expectation.prefix))
      #expect(label.contains(expectation.containsText))
      #expect(!label.contains("Source signal_"))
      #expect(label.hasSuffix("No actions available"))
    }
  }
}

@MainActor
@Suite("Monitor timeline signal VO label — action availability")
struct MonitorTimelineSignalVOActionTests {
  @Test("Pending signal VO label includes Cancel available — ordering contract")
  func pendingSignalVOLabelIncludesCancelAvailable() throws {
    let signalID = "sig-pending-1"
    let entry = makeEntry(
      id: "e-pending",
      kind: "signal_sent",
      summary: "agent sent signal \(signalID): inject_context",
      payload: .object(["signal_id": .string(signalID)])
    )
    let record = SessionSignalRecord(
      runtime: "claude",
      agentId: "agent-1",
      sessionId: "session-1",
      status: .pending,
      signal: Signal(
        signalId: signalID,
        version: 1,
        createdAt: "2026-01-01T00:00:00Z",
        expiresAt: "2099-12-31T23:59:59Z",
        sourceAgent: "agent-1",
        command: "inject_context",
        priority: .normal,
        payload: SignalPayload(
          message: "test",
          actionHint: nil,
          relatedFiles: [],
          metadata: .object([:])
        ),
        delivery: DeliveryConfig(maxRetries: 3, retryCount: 0, idempotencyKey: nil)
      ),
      acknowledgment: nil
    )
    let context = TimelineFeatureContext(
      now: Date(timeIntervalSince1970: 0),
      signalsByID: [signalID: record]
    )
    let nodes = SessionTimelineNodeBuilder(
      sessionID: "session-1",
      entries: [entry],
      decisions: [],
      context: context
    ).build()
    let rows = SessionTimelineRow.rows(for: nodes, configuration: .default)
    let label = try #require(rows.first?.accessibilityLabel)
    #expect(label.contains("Cancel available"), "Expected 'Cancel available' in '\(label)'")
    #expect(
      !label.contains("No actions available"),
      "VO label incorrectly says no actions for pending signal: '\(label)'"
    )
  }

  @Test("Expired signal VO label includes Resend available")
  func expiredSignalVOLabelIncludesResendAvailable() throws {
    let signalID = "sig-expired-1"
    let entry = makeEntry(
      id: "e-expired",
      kind: "signal_acknowledged",
      summary: "signal \(signalID) expired without acknowledgement: Expired",
      payload: .object(["signal_id": .string(signalID)])
    )
    let record = SessionSignalRecord(
      runtime: "claude",
      agentId: "agent-1",
      sessionId: "session-1",
      status: .expired,
      signal: Signal(
        signalId: signalID,
        version: 1,
        createdAt: "2026-01-01T00:00:00Z",
        expiresAt: "2000-01-01T00:00:01Z",
        sourceAgent: "agent-1",
        command: "inject_context",
        priority: .normal,
        payload: SignalPayload(
          message: "test",
          actionHint: nil,
          relatedFiles: [],
          metadata: .object([:])
        ),
        delivery: DeliveryConfig(maxRetries: 3, retryCount: 0, idempotencyKey: nil)
      ),
      acknowledgment: nil
    )
    let context = TimelineFeatureContext(
      now: Date(timeIntervalSince1970: 0),
      signalsByID: [signalID: record]
    )
    let nodes = SessionTimelineNodeBuilder(
      sessionID: "session-1",
      entries: [entry],
      decisions: [],
      context: context
    ).build()
    let rows = SessionTimelineRow.rows(for: nodes, configuration: .default)
    let label = try #require(rows.first?.accessibilityLabel)
    #expect(label.contains("Resend available"), "Expected 'Resend available' in '\(label)'")
  }

  @Test("Delivered signal VO label has no inline actions")
  func deliveredSignalVOLabelHasNoActions() throws {
    let signalID = "sig-delivered-1"
    let entry = makeEntry(
      id: "e-delivered",
      kind: "signal_acknowledged",
      summary: "\(signalID) delivered to agent-2: Accepted",
      payload: .object(["signal_id": .string(signalID)])
    )
    let record = SessionSignalRecord(
      runtime: "claude",
      agentId: "agent-1",
      sessionId: "session-1",
      status: .delivered,
      signal: Signal(
        signalId: signalID,
        version: 1,
        createdAt: "2026-01-01T00:00:00Z",
        expiresAt: "2099-12-31T23:59:59Z",
        sourceAgent: "agent-1",
        command: "inject_context",
        priority: .normal,
        payload: SignalPayload(
          message: "test",
          actionHint: nil,
          relatedFiles: [],
          metadata: .object([:])
        ),
        delivery: DeliveryConfig(maxRetries: 3, retryCount: 0, idempotencyKey: nil)
      ),
      acknowledgment: nil
    )
    let context = TimelineFeatureContext(
      now: Date(timeIntervalSince1970: 0),
      signalsByID: [signalID: record]
    )
    let nodes = SessionTimelineNodeBuilder(
      sessionID: "session-1",
      entries: [entry],
      decisions: [],
      context: context
    ).build()
    let rows = SessionTimelineRow.rows(for: nodes, configuration: .default)
    let label = try #require(rows.first?.accessibilityLabel)
    #expect(label.contains("No actions available"), "Expected 'No actions available' in '\(label)'")
  }
}

@MainActor
@Suite("Signal ID extraction")
struct MonitorTimelineSignalIDTests {
  @Test("signal_sent top-level signal_id is extracted")
  func signalSentExtractsTopLevelID() {
    let entry = makeEntry(
      id: "e1",
      kind: "signal_sent",
      payload: .object([
        "signal_id": .string("abc-123"),
        "command": .string("inject_context"),
      ])
    )
    let nodes = SessionTimelineNodeBuilder(sessionID: "s1", entries: [entry], decisions: []).build()
    #expect(nodes.first?.tapTarget == .signal(id: "abc-123"))
  }

  @Test("signal_acknowledged top-level signal_id is extracted")
  func signalAcknowledgedExtractsTopLevelID() {
    let entry = makeEntry(
      id: "e2",
      kind: "signal_acknowledged",
      payload: .object([
        "signal_id": .string("xyz-456"),
        "result": .string("Accepted"),
      ])
    )
    let nodes = SessionTimelineNodeBuilder(sessionID: "s1", entries: [entry], decisions: []).build()
    #expect(nodes.first?.tapTarget == .signal(id: "xyz-456"))
  }

  @Test("signal_received nested event.signal_id is extracted")
  func signalReceivedExtractsNestedID() {
    let entry = makeEntry(
      id: "e3",
      kind: "signal_received",
      payload: .object([
        "runtime": .string("codex"),
        "event": .object([
          "type": .string("signal_received"),
          "signal_id": .string("def-789"),
        ]),
      ])
    )
    let nodes = SessionTimelineNodeBuilder(sessionID: "s1", entries: [entry], decisions: []).build()
    #expect(nodes.first?.tapTarget == .signal(id: "def-789"))
  }

  @Test("non-signal entry has nil tapTarget")
  func nonSignalEntryHasNilTapTarget() {
    let entry = makeEntry(
      id: "e4",
      kind: "tool_result",
      payload: .object(["signal_id": .string("should-be-ignored")])
    )
    let nodes = SessionTimelineNodeBuilder(sessionID: "s1", entries: [entry], decisions: []).build()
    #expect(nodes.first?.tapTarget == nil)
  }
}

private struct MonitorTimelineSignalExpectation {
  let id: String
  let prefix: String
  let containsText: String
}

private func makeEntry(
  id: String = "entry-1",
  kind: String,
  summary: String = "Timeline event",
  payload: JSONValue = .object([:])
) -> TimelineEntry {
  TimelineEntry(
    entryId: id,
    recordedAt: "2026-04-30T12:00:00Z",
    kind: kind,
    sessionId: "session-1",
    agentId: nil,
    taskId: nil,
    summary: summary,
    payload: payload
  )
}
