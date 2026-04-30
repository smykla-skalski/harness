import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("Session cockpit timeline section")
struct SessionCockpitTimelineSectionTests {
  @Test("Node builder merges streams with deterministic ordering")
  func nodeBuilderMergesStreamsWithDeterministicOrdering() {
    let timestamp = Date(timeIntervalSince1970: 1_775_000_000)
    let recordedAt = isoString(timestamp)
    let decision = makeDecision(id: "decision-a", createdAt: timestamp)
    let nodes = SessionTimelineNodeBuilder(
      sessionID: "session-1",
      entries: [
        makeTimelineEntry(entryID: "event-a", recordedAt: recordedAt),
        makeTimelineEntry(
          entryID: "linked-a",
          recordedAt: recordedAt,
          payload: .object(["decisionID": .string(decision.id)])
        ),
      ],
      decisions: [decision]
    )
    .build()

    #expect(nodes.map(\.kind) == [.decision, .linkedDecision, .event])
    #expect(nodes.map(\.id) == ["decision:decision-a", "entry:linked-a", "entry:event-a"])
  }

  @Test("Tone mapping classifies event severity")
  func toneMappingClassifiesEventSeverity() {
    #expect(
      SessionTimelineTone.eventTone(for: makeTimelineEntry(kind: "task_completed")) == .success
    )
    #expect(
      SessionTimelineTone.eventTone(for: makeTimelineEntry(kind: "retry_warning")) == .warning
    )
    #expect(
      SessionTimelineTone.eventTone(for: makeTimelineEntry(kind: "tool_failed")) == .critical
    )
    #expect(SessionTimelineTone.eventTone(for: makeTimelineEntry(kind: "signal_sent")) == .info)
  }

  @Test("Decision snapshot routes resolve snooze and dismiss actions through the handler")
  func decisionSnapshotRoutesActionsThroughHandler() async {
    let actions = [
      SuggestedAction(id: "resolve", title: "Resolve", kind: .nudge, payloadJSON: "{}"),
      SuggestedAction(
        id: "defer",
        title: "Defer",
        kind: .snooze,
        payloadJSON: #"{"duration":900}"#
      ),
      SuggestedAction(id: "dismiss", title: "Dismiss", kind: .dismiss, payloadJSON: "{}"),
    ]
    let decision = makeDecision(id: "decision-actions", suggestedActionsJSON: encoded(actions))
    let snapshot = SessionTimelineDecisionSnapshot(decision: decision)
    let handler = RecordingTimelineDecisionActionHandler()

    await snapshot.actions[0].perform(using: handler)
    await snapshot.actions[1].perform(using: handler)
    await snapshot.actions[2].perform(using: handler)

    #expect(handler.resolved.count == 1)
    #expect(handler.resolved.first?.decisionID == "decision-actions")
    #expect(handler.resolved.first?.actionID == "resolve")
    #expect(handler.snoozed.count == 1)
    #expect(handler.snoozed.first?.decisionID == "decision-actions")
    #expect(handler.snoozed.first?.duration == 900)
    #expect(handler.dismissed == ["decision-actions"])
  }

  @Test("Entries link to decisions only through explicit payload decision ids")
  func entriesLinkToDecisionsOnlyThroughExplicitPayloadDecisionIDs() {
    let decision = makeDecision(id: "decision-explicit")
    let nodes = SessionTimelineNodeBuilder(
      sessionID: "session-1",
      entries: [
        makeTimelineEntry(
          entryID: "top-level",
          payload: .object(["decisionID": .string(decision.id)])
        ),
        makeTimelineEntry(
          entryID: "supervisor",
          payload: .object(["supervisor": .object(["decision_id": .string(decision.id)])])
        ),
      ],
      decisions: [decision]
    )
    .build()
    let linkedEntries = nodes.filter { $0.kind == .linkedDecision }

    #expect(linkedEntries.map(\.id).sorted() == ["entry:supervisor", "entry:top-level"])
    #expect(linkedEntries.allSatisfy { !$0.actions.isEmpty })
  }

  @Test("Builder does not infer decision links from summary task agent or rule context")
  func builderDoesNotInferDecisionLinksFromHeuristics() {
    let decision = makeDecision(
      id: "decision-heuristic",
      ruleID: "rule.heuristic",
      agentID: "agent-1",
      taskID: "task-1"
    )
    let nodes = SessionTimelineNodeBuilder(
      sessionID: "session-1",
      entries: [
        makeTimelineEntry(
          entryID: "plain-event",
          agentID: "agent-1",
          taskID: "task-1",
          summary: "decision-heuristic rule.heuristic needs work",
          payload: .object(["ruleID": .string("rule.heuristic")])
        )
      ],
      decisions: [decision]
    )
    .build()
    let event = nodes.first { $0.id == "entry:plain-event" }

    #expect(event?.kind == .event)
    #expect(event?.actions.isEmpty == true)
  }

  private func makeTimelineEntry(
    entryID: String = "entry-1",
    recordedAt: String = "2026-04-30T12:00:00Z",
    kind: String = "signal_sent",
    agentID: String? = "agent-1",
    taskID: String? = nil,
    summary: String = "Timeline event",
    payload: JSONValue = .object([:])
  ) -> TimelineEntry {
    TimelineEntry(
      entryId: entryID,
      recordedAt: recordedAt,
      kind: kind,
      sessionId: "session-1",
      agentId: agentID,
      taskId: taskID,
      summary: summary,
      payload: payload
    )
  }

  private func makeDecision(
    id: String,
    severity: DecisionSeverity = .warn,
    ruleID: String = "rule.timeline",
    sessionID: String? = "session-1",
    agentID: String? = nil,
    taskID: String? = nil,
    createdAt: Date = Date(timeIntervalSince1970: 1_775_000_000),
    suggestedActionsJSON: String = "[]"
  ) -> Decision {
    let decision = Decision(
      id: id,
      severity: severity,
      ruleID: ruleID,
      sessionID: sessionID,
      agentID: agentID,
      taskID: taskID,
      summary: "Decision \(id)",
      contextJSON: "{}",
      suggestedActionsJSON: suggestedActionsJSON
    )
    decision.createdAt = createdAt
    return decision
  }

  private func encoded(_ actions: [SuggestedAction]) -> String {
    let data = try? JSONEncoder().encode(actions)
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
  }

  private func isoString(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }
}

@MainActor
private final class RecordingTimelineDecisionActionHandler: DecisionActionHandler {
  var resolved: [(decisionID: String, actionID: String?)] = []
  var snoozed: [(decisionID: String, duration: TimeInterval)] = []
  var dismissed: [String] = []

  func resolve(decisionID: String, outcome: DecisionOutcome) async {
    resolved.append((decisionID, outcome.chosenActionID))
  }

  func snooze(decisionID: String, duration: TimeInterval) async {
    snoozed.append((decisionID, duration))
  }

  func dismiss(decisionID: String) async {
    dismissed.append(decisionID)
  }
}

@Suite("SessionTimeline placeholder shimmer")
struct SessionTimelinePlaceholderShimmerTests {
  @Test("Shared shimmer animates only when unresolved placeholders are visible")
  func sharedShimmerAnimatesOnlyWhenNeeded() {
    #expect(
      SessionTimelinePlaceholderShimmer.shouldAnimate(
        reduceMotion: false,
        placeholderCount: 4
      )
    )
    #expect(
      SessionTimelinePlaceholderShimmer.shouldAnimate(
        reduceMotion: true,
        placeholderCount: 4
      ) == false
    )
    #expect(
      SessionTimelinePlaceholderShimmer.shouldAnimate(
        reduceMotion: false,
        placeholderCount: 0
      ) == false
    )
  }

  @Test("Shared shimmer phase stays in the expected horizontal travel range")
  func sharedShimmerPhaseStaysInExpectedRange() {
    let cycleDuration = SessionTimelinePlaceholderShimmer.cycleDuration
    let phaseAtStart = SessionTimelinePlaceholderShimmer.phase(
      at: Date(timeIntervalSinceReferenceDate: 0)
    )
    let phaseMidCycle = SessionTimelinePlaceholderShimmer.phase(
      at: Date(timeIntervalSinceReferenceDate: cycleDuration / 2)
    )
    let phaseAtWrap = SessionTimelinePlaceholderShimmer.phase(
      at: Date(timeIntervalSinceReferenceDate: cycleDuration)
    )

    #expect(phaseAtStart == -0.6)
    #expect(phaseMidCycle == 0.6)
    #expect(phaseAtWrap == -0.6)
  }
}
