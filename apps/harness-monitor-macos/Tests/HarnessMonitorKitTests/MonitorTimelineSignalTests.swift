import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("Monitor timeline signal tone")
struct MonitorTimelineSignalToneTests {
  @Test("Signal tone dispatches on summary text not kind string")
  func signalToneDispatchesOnSummaryText() {
    #expect(
      SessionTimelineTone.eventTone(for: makeEntry(
        kind: "signal_acknowledged",
        summary: "sig-abc delivered to codex-worker: Accepted"
      )) == .success
    )
    #expect(
      SessionTimelineTone.eventTone(for: makeEntry(
        kind: "signal_acknowledged",
        summary: "sig-abc rejected from codex-worker: Rejected"
      )) == .critical
    )
    #expect(
      SessionTimelineTone.eventTone(for: makeEntry(
        kind: "signal_acknowledged",
        summary: "sig-abc deferred by codex-worker: Deferred"
      )) == .warning
    )
    #expect(
      SessionTimelineTone.eventTone(for: makeEntry(
        kind: "signal_acknowledged",
        summary: "sig-abc expired without acknowledgement: Expired"
      )) == .warning
    )
    #expect(
      SessionTimelineTone.eventTone(for: makeEntry(
        kind: "signal_sent",
        summary: "codex-worker sent signal sig-abc: inject_context"
      )) == .info
    )
    #expect(
      SessionTimelineTone.eventTone(for: makeEntry(
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
      makeEntry(id: "sig-sent", kind: "signal_sent",
        summary: "codex-worker sent signal sig-abc: inject_context"),
      makeEntry(id: "sig-received", kind: "signal_received",
        summary: "codex-worker picked up sig-abc: inject_context"),
      makeEntry(id: "sig-accepted", kind: "signal_acknowledged",
        summary: "sig-abc delivered to codex-worker: Accepted"),
      makeEntry(id: "sig-rejected", kind: "signal_acknowledged",
        summary: "sig-abc rejected from codex-worker: Rejected"),
      makeEntry(id: "sig-deferred", kind: "signal_acknowledged",
        summary: "sig-abc deferred by codex-worker: Deferred"),
      makeEntry(id: "sig-expired", kind: "signal_acknowledged",
        summary: "sig-abc expired without acknowledgement: Expired"),
    ]
    let nodes = SessionTimelineNodeBuilder(
      sessionID: "session-1", entries: entries, decisions: []
    ).build()
    let rows = SessionTimelineRow.rows(for: nodes, configuration: .default)
    let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })

    let expectations: [(id: String, prefix: String, body: String)] = [
      ("entry:sig-sent", "Signal sent", "codex-worker sent signal"),
      ("entry:sig-received", "Signal received", "picked up"),
      ("entry:sig-accepted", "Signal delivered", "Accepted"),
      ("entry:sig-rejected", "Signal rejected", "Rejected"),
      ("entry:sig-deferred", "Signal deferred", "Deferred"),
      ("entry:sig-expired", "Signal expired", "Expired"),
    ]
    for (id, prefix, body) in expectations {
      let label = try #require(byID[id]?.accessibilityLabel)
      #expect(label.hasPrefix(prefix))
      #expect(label.contains(body))
      #expect(!label.contains("Source signal_"))
      #expect(label.hasSuffix("No actions"))
    }
  }
}

@MainActor
@Suite("Signal ID extraction")
struct MonitorTimelineSignalIDTests {
  @Test("signal_sent top-level signal_id is extracted")
  func signalSentExtractsTopLevelID() {
    let entry = makeEntry(
      id: "e1", kind: "signal_sent",
      payload: .object(["signal_id": .string("abc-123"), "command": .string("inject_context")])
    )
    let nodes = SessionTimelineNodeBuilder(sessionID: "s1", entries: [entry], decisions: []).build()
    #expect(nodes.first?.signalID == "abc-123")
  }

  @Test("signal_acknowledged top-level signal_id is extracted")
  func signalAcknowledgedExtractsTopLevelID() {
    let entry = makeEntry(
      id: "e2", kind: "signal_acknowledged",
      payload: .object(["signal_id": .string("xyz-456"), "result": .string("Accepted")])
    )
    let nodes = SessionTimelineNodeBuilder(sessionID: "s1", entries: [entry], decisions: []).build()
    #expect(nodes.first?.signalID == "xyz-456")
  }

  @Test("signal_received nested event.signal_id is extracted")
  func signalReceivedExtractsNestedID() {
    let entry = makeEntry(
      id: "e3", kind: "signal_received",
      payload: .object([
        "runtime": .string("codex"),
        "event": .object(["type": .string("signal_received"), "signal_id": .string("def-789")]),
      ])
    )
    let nodes = SessionTimelineNodeBuilder(sessionID: "s1", entries: [entry], decisions: []).build()
    #expect(nodes.first?.signalID == "def-789")
  }

  @Test("non-signal entry has nil signalID")
  func nonSignalEntryHasNilID() {
    let entry = makeEntry(
      id: "e4", kind: "tool_result",
      payload: .object(["signal_id": .string("should-be-ignored")])
    )
    let nodes = SessionTimelineNodeBuilder(sessionID: "s1", entries: [entry], decisions: []).build()
    #expect(nodes.first?.signalID == nil)
  }
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
