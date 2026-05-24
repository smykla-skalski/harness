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

  @Test("Narrow push observes task and metric diffs even when summary updatedAt is stable")
  func narrowPushObservesTaskDiffsWithoutUpdatedAtBump() {
    let slice = HarnessMonitorStore.ContentSessionDetailSlice()
    let summary = PreviewFixtures.summary
    let updatedSummary = replacingMetrics(
      summary,
      with: SessionMetrics(
        agentCount: summary.metrics.agentCount,
        activeAgentCount: summary.metrics.activeAgentCount,
        idleAgentCount: summary.metrics.idleAgentCount,
        awaitingReviewAgentCount: summary.metrics.awaitingReviewAgentCount,
        openTaskCount: summary.metrics.openTaskCount + 1,
        inProgressTaskCount: summary.metrics.inProgressTaskCount,
        awaitingReviewTaskCount: summary.metrics.awaitingReviewTaskCount + 1,
        inReviewTaskCount: summary.metrics.inReviewTaskCount,
        arbitrationTaskCount: summary.metrics.arbitrationTaskCount,
        blockedTaskCount: summary.metrics.blockedTaskCount,
        completedTaskCount: summary.metrics.completedTaskCount
      )
    )
    let tasks =
      PreviewFixtures.tasks
      + [
        WorkItem(
          taskId: "task-awaiting-review",
          title: "Awaiting review",
          context: "Task-only push with a stable summary timestamp.",
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
    let initialDetail = SessionDetail(
      session: summary,
      agents: PreviewFixtures.agents,
      tasks: PreviewFixtures.tasks,
      signals: PreviewFixtures.signals,
      observer: PreviewFixtures.observer,
      agentActivity: PreviewFixtures.agentActivity
    )
    let updatedDetail = SessionDetail(
      session: updatedSummary,
      agents: PreviewFixtures.agents,
      tasks: tasks,
      signals: PreviewFixtures.signals,
      observer: PreviewFixtures.observer,
      agentActivity: PreviewFixtures.agentActivity
    )

    slice.apply(
      HarnessMonitorStore.ContentSessionDetailState(selectedSessionDetail: initialDetail),
      selectedSessionSummary: summary
    )
    slice.apply(
      HarnessMonitorStore.ContentSessionDetailState(selectedSessionDetail: updatedDetail),
      selectedSessionSummary: updatedSummary
    )

    #expect(summary.updatedAt == updatedSummary.updatedAt)
    #expect(slice.selectedSessionTasks == tasks)
    #expect(slice.selectedSessionSession?.metrics == updatedSummary.metrics)
  }

  @Test("Arbitration banner tasks recompute as session detail rotates")
  func arbitrationBannerTasksRecomputeOnDetailSwap() {
    let slice = HarnessMonitorStore.ContentSessionDetailSlice()
    let summary = PreviewFixtures.summary

    let plainDetail = PreviewFixtures.sessionDetail(session: summary)
    var plainState = HarnessMonitorStore.ContentSessionDetailState()
    plainState.selectedSessionDetail = plainDetail
    slice.apply(plainState, selectedSessionSummary: summary)

    #expect(slice.arbitrationBannerTasks.isEmpty)

    let arbitrationCandidate = WorkItem(
      taskId: "task-arbitration-round",
      title: "Needs arbitration",
      context: nil,
      severity: .high,
      status: .inReview,
      assignedTo: nil,
      createdAt: "2026-04-24T10:00:00Z",
      updatedAt: "2026-04-24T10:45:00Z",
      createdBy: "leader-claude",
      notes: [],
      suggestedFix: nil,
      source: .manual,
      blockedReason: nil,
      completedAt: nil,
      checkpointSummary: nil,
      reviewRound: 3
    )
    let expandedTasks = PreviewFixtures.tasks + [arbitrationCandidate]
    let expandedSummary = bumpingUpdatedAt(summary, to: "2026-04-24T10:46:00Z")
    let expandedDetail = PreviewFixtures.sessionDetail(
      session: expandedSummary,
      tasks: expandedTasks
    )
    var expandedState = HarnessMonitorStore.ContentSessionDetailState()
    expandedState.selectedSessionDetail = expandedDetail
    slice.apply(expandedState, selectedSessionSummary: expandedSummary)

    #expect(slice.arbitrationBannerTasks == [arbitrationCandidate])

    let restoredSummary = bumpingUpdatedAt(summary, to: "2026-04-24T10:47:00Z")
    let restoredDetail = PreviewFixtures.sessionDetail(session: restoredSummary)
    var restoredState = HarnessMonitorStore.ContentSessionDetailState()
    restoredState.selectedSessionDetail = restoredDetail
    slice.apply(restoredState, selectedSessionSummary: restoredSummary)

    #expect(slice.arbitrationBannerTasks.isEmpty)
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

  private func replacingMetrics(
    _ summary: SessionSummary,
    with metrics: SessionMetrics
  ) -> SessionSummary {
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
      updatedAt: summary.updatedAt,
      lastActivityAt: summary.lastActivityAt,
      leaderId: summary.leaderId,
      observeId: summary.observeId,
      pendingLeaderTransfer: summary.pendingLeaderTransfer,
      externalOrigin: summary.externalOrigin,
      adoptedAt: summary.adoptedAt,
      metrics: metrics
    )
  }
}
