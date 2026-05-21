import AppKit
import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("Monitor timeline section")
struct MonitorTimelineSectionTests {
  @Test("Node builder merges streams with deterministic ordering")
  func nodeBuilderMergesStreamsWithDeterministicOrdering() {
    let timestamp = Date(timeIntervalSince1970: 1_775_000_000)
    let recordedAt = MonitorTimelineSectionFixtures.isoString(timestamp)
    let decision = MonitorTimelineSectionFixtures.makeDecision(
      id: "decision-a",
      createdAt: timestamp
    )
    let nodes = SessionTimelineNodeBuilder(
      sessionID: "session-1",
      entries: [
        MonitorTimelineSectionFixtures.makeTimelineEntry(
          entryID: "event-a",
          recordedAt: recordedAt
        ),
        MonitorTimelineSectionFixtures.makeTimelineEntry(
          entryID: "linked-a",
          recordedAt: recordedAt,
          payload: .object(["decisionID": .string(decision.id)])
        ),
      ],
      decisions: [SessionTimelineDecisionInput(decision: decision)]
    )
    .build()

    #expect(nodes.map(\.kind) == [.decision, .linkedDecision, .event])
    #expect(nodes.map(\.id) == ["decision:decision-a", "entry:linked-a", "entry:event-a"])
  }

  @Test("Tone mapping classifies event severity")
  func toneMappingClassifiesEventSeverity() {
    #expect(
      SessionTimelineTone.eventTone(
        for: MonitorTimelineSectionFixtures.makeTimelineEntry(kind: "task_completed")
      ) == .success
    )
    #expect(
      SessionTimelineTone.eventTone(
        for: MonitorTimelineSectionFixtures.makeTimelineEntry(kind: "retry_warning")
      ) == .warning
    )
    #expect(
      SessionTimelineTone.eventTone(
        for: MonitorTimelineSectionFixtures.makeTimelineEntry(kind: "tool_failed")
      ) == .critical
    )
    #expect(
      SessionTimelineTone.eventTone(
        for: MonitorTimelineSectionFixtures.makeTimelineEntry(kind: "signal_sent")
      ) == .info
    )
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
    let decision = MonitorTimelineSectionFixtures.makeDecision(
      id: "decision-actions",
      suggestedActionsJSON: MonitorTimelineSectionFixtures.encoded(actions)
    )
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

  @Test("Decision index reuses one decoder while building timeline snapshots")
  func decisionIndexReusesOneDecoderWhileBuildingTimelineSnapshots() throws {
    let nodeBuilderSource = try timelineSourceFile(named: "SessionTimelineNodeBuilder.swift")
    let snapshotSource = try timelineSourceFile(named: "SessionTimelineDecisionSnapshot.swift")

    #expect(nodeBuilderSource.contains("let actionsDecoder = JSONDecoder()"))
    #expect(
      nodeBuilderSource.contains(
        "SessionTimelineDecisionSnapshot(input: $0, actionsDecoder: actionsDecoder)"
      )
    )
    #expect(
      snapshotSource.contains(
        "actionsDecoder: JSONDecoder = sessionTimelineActionsDecoder"
      )
    )
    #expect(
      snapshotSource.contains(
        "let parsedActions = parseActions(from: decision.suggestedActionsJSON, decoder: decoder)"
      )
    )
  }

  @Test("Entries link to decisions only through explicit payload decision ids")
  func entriesLinkToDecisionsOnlyThroughExplicitPayloadDecisionIDs() {
    let decision = MonitorTimelineSectionFixtures.makeDecision(id: "decision-explicit")
    let nodes = SessionTimelineNodeBuilder(
      sessionID: "session-1",
      entries: [
        MonitorTimelineSectionFixtures.makeTimelineEntry(
          entryID: "top-level",
          payload: .object(["decisionID": .string(decision.id)])
        ),
        MonitorTimelineSectionFixtures.makeTimelineEntry(
          entryID: "supervisor",
          payload: .object(["supervisor": .object(["decision_id": .string(decision.id)])])
        ),
      ],
      decisions: [SessionTimelineDecisionInput(decision: decision)]
    )
    .build()
    let linkedEntries = nodes.filter { $0.kind == .linkedDecision }

    #expect(linkedEntries.map(\.id).sorted() == ["entry:supervisor", "entry:top-level"])
    #expect(linkedEntries.allSatisfy { $0.decision?.actions.isEmpty == false })
  }

  @Test("Builder does not infer decision links from summary task agent or rule context")
  func builderDoesNotInferDecisionLinksFromHeuristics() {
    let decision = MonitorTimelineSectionFixtures.makeDecision(
      id: "decision-heuristic",
      ruleID: "rule.heuristic",
      agentID: "agent-1",
      taskID: "task-1"
    )
    let nodes = SessionTimelineNodeBuilder(
      sessionID: "session-1",
      entries: [
        MonitorTimelineSectionFixtures.makeTimelineEntry(
          entryID: "plain-event",
          agentID: "agent-1",
          taskID: "task-1",
          summary: "decision-heuristic rule.heuristic needs work",
          payload: .object(["ruleID": .string("rule.heuristic")])
        )
      ],
      decisions: [SessionTimelineDecisionInput(decision: decision)]
    )
    .build()
    let event = nodes.first { $0.id == "entry:plain-event" }

    #expect(event?.kind == .event)
    #expect(event?.actions.isEmpty == true)
  }

  @Test("Filter controls keep a stable stacked layout across widths")
  func filterControlsKeepStableStackedLayoutAcrossWidths() {
    let mediumHeight = measuredFilterControlsHeight(width: 540)
    let wideHeight = measuredFilterControlsHeight(width: 680)

    #expect(abs(mediumHeight - wideHeight) <= 1)
  }

  private func measuredFilterControlsHeight(width: CGFloat) -> CGFloat {
    let host = NSHostingView(
      rootView: TimelineFilterControlsLayoutProbe()
        .frame(width: width)
        .harnessPreviewSceneAppearance()
    )
    host.frame = CGRect(x: 0, y: 0, width: width, height: 200)
    host.layoutSubtreeIfNeeded()
    return host.fittingSize.height
  }

  private func timelineSourceFile(named fileName: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent(
        "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Views/Timeline"
      )
      .appendingPathComponent(fileName)
    return try String(contentsOf: fileURL, encoding: .utf8)
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

  func cancelSignal(signalID: String, agentID: String) async {}
  func resendSignal(_ record: SessionSignalRecord) async {}
}

private struct TimelineFilterControlsLayoutProbe: View {
  @State private var filters = SessionTimelineFilterState()

  var body: some View {
    SessionTimelineFilterControls(
      filters: $filters,
      inventory: .empty,
      summary: .empty
    )
  }
}
