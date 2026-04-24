import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Review streaming narrow apply")
struct ReviewStreamingTests {
  @Test("Narrow push writes tasks slice and leaves agents/signals/observer/activity untouched")
  func narrowPushPreservesUnchangedSubSlices() {
    let slice = HarnessMonitorStore.ContentSessionDetailSlice()
    let summaryA = PreviewFixtures.summary
    let summaryB = bumpingUpdatedAt(summaryA, to: "2026-03-28T14:22:00Z")

    let tasksA = PreviewFixtures.tasks
    let tasksB =
      tasksA
      + [
        WorkItem(
          taskId: "task-review",
          title: "Awaiting review - reviewer quorum",
          context: "Track how the narrow push lands.",
          severity: .medium,
          status: .awaitingReview,
          assignedTo: nil,
          createdAt: "2026-03-28T14:21:00Z",
          updatedAt: "2026-03-28T14:21:00Z",
          createdBy: "leader-claude",
          notes: [],
          suggestedFix: nil,
          source: .manual,
          blockedReason: nil,
          completedAt: nil,
          checkpointSummary: nil
        )
      ]

    let detailA = PreviewFixtures.sessionDetail(session: summaryA, tasks: tasksA)
    let detailB = PreviewFixtures.sessionDetail(session: summaryB, tasks: tasksB)

    var stateA = HarnessMonitorStore.ContentSessionDetailState()
    stateA.selectedSessionDetail = detailA
    slice.apply(stateA, selectedSessionSummary: summaryA)

    #expect(slice.selectedSessionTasks == tasksA)
    #expect(slice.selectedSessionAgents == detailA.agents)
    #expect(slice.selectedSessionSignals == detailA.signals)
    #expect(slice.selectedSessionObserver == detailA.observer)
    #expect(slice.selectedSessionAgentActivity == detailA.agentActivity)
    let agentsBefore = slice.selectedSessionAgents
    let signalsBefore = slice.selectedSessionSignals
    let observerBefore = slice.selectedSessionObserver
    let activityBefore = slice.selectedSessionAgentActivity

    var stateB = HarnessMonitorStore.ContentSessionDetailState()
    stateB.selectedSessionDetail = detailB
    slice.apply(stateB, selectedSessionSummary: summaryB)

    #expect(slice.selectedSessionTasks == tasksB)
    #expect(slice.selectedSessionAgents == agentsBefore)
    #expect(slice.selectedSessionSignals == signalsBefore)
    #expect(slice.selectedSessionObserver == observerBefore)
    #expect(slice.selectedSessionAgentActivity == activityBefore)
    #expect(slice.selectedSessionSession?.updatedAt == summaryB.updatedAt)
  }

  private func bumpingUpdatedAt(_ summary: SessionSummary, to updatedAt: String) -> SessionSummary {
    SessionSummary(
      projectId: summary.projectId,
      projectName: summary.projectName,
      projectDir: summary.projectDir,
      contextRoot: summary.contextRoot,
      sessionId: summary.sessionId,
      worktreePath: summary.worktreePath,
      sharedPath: summary.sharedPath,
      originPath: summary.originPath,
      branchRef: summary.branchRef,
      title: summary.title,
      context: summary.context,
      status: summary.status,
      createdAt: summary.createdAt,
      updatedAt: updatedAt,
      lastActivityAt: summary.lastActivityAt,
      leaderId: summary.leaderId,
      observeId: summary.observeId,
      pendingLeaderTransfer: summary.pendingLeaderTransfer,
      externalOrigin: summary.externalOrigin,
      adoptedAt: summary.adoptedAt,
      metrics: summary.metrics
    )
  }
}
