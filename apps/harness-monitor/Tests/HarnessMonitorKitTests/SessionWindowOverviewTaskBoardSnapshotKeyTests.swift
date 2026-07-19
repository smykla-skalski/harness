import HarnessMonitorKit
import Testing

@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("SessionWindowOverview task-board snapshot key")
struct SessionWindowOverviewTaskBoardSnapshotKeyTests {
  @Test("Key stays stable when nothing about the session or its tasks changed")
  func keyStableForIdenticalSnapshot() {
    let overview = makeOverview(detail: PreviewFixtures.detail)
    let sameOverview = makeOverview(detail: PreviewFixtures.detail)

    #expect(overview.taskBoardSnapshotKey == sameOverview.taskBoardSnapshotKey)
  }

  @Test("Key changes when a task's status mutates")
  func keyChangesWhenTaskMutates() {
    let baseTask = PreviewFixtures.tasks[0]
    let mutatedStatus: TaskStatus = baseTask.status == .blocked ? .open : .blocked
    let mutatedTask = WorkItem(
      taskId: baseTask.taskId,
      title: baseTask.title,
      context: baseTask.context,
      severity: baseTask.severity,
      status: mutatedStatus,
      assignedTo: baseTask.assignedTo,
      queuePolicy: baseTask.queuePolicy,
      queuedAt: baseTask.queuedAt,
      createdAt: baseTask.createdAt,
      updatedAt: baseTask.updatedAt,
      createdBy: baseTask.createdBy,
      notes: baseTask.notes,
      suggestedFix: baseTask.suggestedFix,
      source: baseTask.source,
      blockedReason: baseTask.blockedReason,
      completedAt: baseTask.completedAt,
      checkpointSummary: baseTask.checkpointSummary,
      awaitingReview: baseTask.awaitingReview,
      reviewClaim: baseTask.reviewClaim,
      consensus: baseTask.consensus,
      reviewRound: baseTask.reviewRound,
      arbitration: baseTask.arbitration,
      suggestedPersona: baseTask.suggestedPersona,
      reviewHistory: baseTask.reviewHistory
    )
    let mutatedDetail = SessionDetail(
      session: PreviewFixtures.detail.session,
      agents: PreviewFixtures.detail.agents,
      tasks: PreviewFixtures.detail.tasks.map { $0.taskId == baseTask.taskId ? mutatedTask : $0 },
      signals: PreviewFixtures.detail.signals,
      observer: PreviewFixtures.detail.observer,
      agentActivity: PreviewFixtures.detail.agentActivity
    )

    let before = makeOverview(detail: PreviewFixtures.detail)
    let after = makeOverview(detail: mutatedDetail)

    #expect(before.taskBoardSnapshotKey != after.taskBoardSnapshotKey)
  }

  @Test("Key stays stable when an unrelated store field changes")
  func keyStableAcrossUnrelatedStoreChange() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let snapshot = HarnessMonitorSessionWindowSnapshot(
      summary: PreviewFixtures.summary,
      detail: PreviewFixtures.detail,
      timeline: [],
      timelineWindow: nil,
      source: .live
    )
    let before = SessionWindowOverview(
      store: store,
      snapshot: snapshot,
      decisions: [],
      tuiStatusByAgent: [:]
    ).taskBoardSnapshotKey

    store.selectedAgentTuis = []

    let after = SessionWindowOverview(
      store: store,
      snapshot: snapshot,
      decisions: [],
      tuiStatusByAgent: [:]
    ).taskBoardSnapshotKey

    #expect(before == after)
  }

  private func makeOverview(detail: SessionDetail) -> SessionWindowOverview {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let snapshot = HarnessMonitorSessionWindowSnapshot(
      summary: PreviewFixtures.summary,
      detail: detail,
      timeline: [],
      timelineWindow: nil,
      source: .live
    )
    return SessionWindowOverview(
      store: store,
      snapshot: snapshot,
      decisions: [],
      tuiStatusByAgent: [:]
    )
  }
}
