import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard navigation targets")
struct DashboardNavigationTargetTests {
  @Test("Board targets wait only for the snapshots that can resolve them")
  func boardTargetReadinessUsesRelevantSnapshots() {
    let inboxOnly = DashboardTaskBoardNavigationReadiness(
      taskBoardSnapshotAvailable: false,
      inboxSnapshotAvailable: true
    )
    #expect(!inboxOnly.canReportUnavailable(for: .item(itemID: "item-1")))
    #expect(
      !inboxOnly.canReportUnavailable(
        for: .sessionTask(sessionID: "session-1", taskID: "task-1")
      )
    )
    #expect(
      inboxOnly.canReportUnavailable(
        for: .loadedSessionTask(sessionID: "session-1", taskID: "task-1")
      )
    )

    let both = DashboardTaskBoardNavigationReadiness(
      taskBoardSnapshotAvailable: true,
      inboxSnapshotAvailable: true
    )
    #expect(
      both.canReportUnavailable(
        for: .sessionTask(sessionID: "session-1", taskID: "task-1")
      )
    )
  }

  @Test("Board navigation commits only the current uncancelled request")
  func boardNavigationRejectsStaleContinuations() {
    #expect(
      DashboardTaskBoardNavigationCommitGuard.canCommit(
        requestID: 7,
        pendingRequestID: 7,
        isRouteVisible: true,
        isCancelled: false
      )
    )
    #expect(
      !DashboardTaskBoardNavigationCommitGuard.canCommit(
        requestID: 7,
        pendingRequestID: 8,
        isRouteVisible: true,
        isCancelled: false
      )
    )
    #expect(
      !DashboardTaskBoardNavigationCommitGuard.canCommit(
        requestID: 7,
        pendingRequestID: 7,
        isRouteVisible: true,
        isCancelled: true
      )
    )
    #expect(
      !DashboardTaskBoardNavigationCommitGuard.canCommit(
        requestID: 7,
        pendingRequestID: 7,
        isRouteVisible: false,
        isCancelled: false
      )
    )
  }

  @Test("Terminal creation waits for a catalog before rejecting a missing session")
  func terminalCreationUsesCatalogReadiness() {
    #expect(
      DashboardTerminalCreationNavigationResolution.resolve(
        sessionID: "session-1",
        availableSessionIDs: [],
        catalogIsReady: false
      ) == .waitingForCatalog
    )
    #expect(
      DashboardTerminalCreationNavigationResolution.resolve(
        sessionID: "session-1",
        availableSessionIDs: ["session-1"],
        catalogIsReady: false
      ) == .available
    )
    #expect(
      DashboardTerminalCreationNavigationResolution.resolve(
        sessionID: "session-1",
        availableSessionIDs: [],
        catalogIsReady: true
      ) == .unavailable
    )
  }

  @Test("Timeline targets retain the exact activity outside the audit feed")
  func timelineTargetRetainsActivity() throws {
    let source = OpenAnythingLoadedSessionTimelineTarget(
      entry: TimelineEntry(
        entryId: "entry-1",
        recordedAt: "2026-08-05T08:00:00Z",
        kind: "agent.progress",
        sessionId: "session-1",
        agentId: "agent-1",
        taskId: "task-1",
        summary: "Working",
        payload: .object(["percent": .number(50)])
      )
    )
    let target = DashboardAuditNavigationTarget.sessionTimeline(.init(source))
    let event = try #require(target.routedEvent)

    #expect(target.eventID == "timeline:session-1:entry-1")
    #expect(event.id == target.eventID)
    #expect(event.source == "sessionTimeline")
    #expect(event.summary == "Working")
    #expect(event.payloadJSON == .object(["percent": .number(50)]))
  }

  @Test("Observer targets retain the exact session snapshot")
  func observerTargetRetainsSnapshot() throws {
    let target = DashboardAuditNavigationTarget.observerSummary(
      DashboardObserverActivityTarget(
        sessionID: "session-1",
        observer: PreviewFixtures.observer
      )
    )
    let event = try #require(target.routedEvent)

    #expect(target.eventID.hasPrefix("observer:session-1:"))
    #expect(event.source == "observer")
    #expect(event.subject == "session-1")
    #expect(event.summary == "3 open issues, 2 active workers")
    #expect(event.payloadJSON != nil)
  }

  @Test("Audit navigation scrolls only to an exact visible event")
  func auditNavigationScrollRequiresVisibleEvent() {
    let target = DashboardAuditTimelineScrollTarget(eventID: "event-500", requestID: 7)

    #expect(
      DashboardAuditTimelineScrollTarget.resolve(
        target,
        availableEventIDs: ["event-1", "event-500"]
      ) == target
    )
    #expect(
      DashboardAuditTimelineScrollTarget.resolve(
        target,
        availableEventIDs: ["event-1"]
      ) == nil
    )
  }

  @Test("Audit selection remains inside the visible prefix as new events arrive")
  func auditSelectionExpandsVisiblePrefix() {
    let eventIDs = (0...40).map { "event-\($0)" }

    #expect(
      DashboardAuditSelectionVisibility.requiredLimit(
        selectedEventID: "event-40",
        orderedEventIDs: eventIDs,
        currentLimit: 40
      ) == 41
    )
    #expect(
      DashboardAuditSelectionVisibility.requiredLimit(
        selectedEventID: "missing",
        orderedEventIDs: eventIDs,
        currentLimit: 40
      ) == nil
    )
  }

  @Test("Decision scrolling activates only an exact available target")
  func decisionScrollTargetRequiresExactMatch() {
    #expect(
      DashboardDecisionScrollTarget.resolve(
        selectedDecisionID: "decision-2",
        requestTick: 3,
        availableDecisionIDs: ["decision-1", "decision-2"]
      ) == .init(decisionID: "decision-2", requestTick: 3)
    )
    #expect(
      DashboardDecisionScrollTarget.resolve(
        selectedDecisionID: "missing",
        requestTick: 3,
        availableDecisionIDs: ["decision-1"]
      ) == nil
    )
    #expect(
      DashboardDecisionScrollTarget.resolve(
        selectedDecisionID: "decision-1",
        requestTick: 0,
        availableDecisionIDs: ["decision-1"]
      ) == nil
    )
  }

  @Test("Decision action focus activates only the exact primary action")
  func decisionActionFocusRequiresExactPrimaryAction() {
    #expect(
      DashboardDecisionActionFocusTarget.resolve(
        decisionID: "decision-1",
        isPrimaryAction: true,
        selectedDecisionID: "decision-1",
        requestTick: 3
      ) == .init(decisionID: "decision-1", requestTick: 3)
    )
    #expect(
      DashboardDecisionActionFocusTarget.resolve(
        decisionID: "decision-1",
        isPrimaryAction: false,
        selectedDecisionID: "decision-1",
        requestTick: 3
      ) == nil
    )
    #expect(
      DashboardDecisionActionFocusTarget.resolve(
        decisionID: "decision-1",
        isPrimaryAction: true,
        selectedDecisionID: "decision-2",
        requestTick: 3
      ) == nil
    )
  }

  @Test("Codex approval navigation shares the rule decision identity")
  func codexApprovalDecisionIdentityIsShared() {
    #expect(
      CodexApprovalRule.decisionID(sessionID: "session-1", approvalID: "approval-1")
        == "codex-approval:session-1:approval-1"
    )
  }
}
