import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Task actions review workflow")
struct TaskActionsReviewWorkflowTests {
  @Test("Assignment candidates are free live workers only")
  func assignmentCandidatesAreFreeLiveWorkersOnly() {
    let agents = [
      makeAgent("worker-free", role: .worker, status: .idle),
      makeAgent("worker-busy", role: .worker, currentTaskID: "task-1"),
      makeAgent("worker-review", role: .worker, status: .awaitingReview),
      makeAgent("leader", role: .leader),
      makeAgent("reviewer", role: .reviewer),
    ]

    #expect(TaskActionsSheet.eligibleAssignmentAgents(agents).map(\.agentId) == ["worker-free"])
  }

  @Test("Review claim candidates skip runtimes already claimed")
  func reviewClaimCandidatesSkipClaimedRuntimes() {
    let task = makeTask(
      status: .inReview,
      reviewClaim: ReviewClaim(reviewers: [
        ReviewerEntry(
          reviewerAgentId: "reviewer-claude",
          reviewerRuntime: "claude",
          claimedAt: "2026-05-14T10:00:00Z"
        )
      ])
    )
    let agents = [
      makeAgent("reviewer-claude-2", runtime: "claude", role: .reviewer),
      makeAgent("reviewer-codex", runtime: "codex", role: .reviewer),
      makeAgent("leader-gemini", runtime: "gemini", role: .leader),
      makeAgent("worker", runtime: "opencode", role: .worker),
    ]

    #expect(
      TaskActionsSheet.eligibleReviewClaimAgents(task: task, agents: agents).map(\.agentId)
        == ["reviewer-codex", "leader-gemini"]
    )
  }

  @Test("Review submit candidates are live claimed reviewers")
  func reviewSubmitCandidatesAreClaimedReviewers() {
    let task = makeTask(
      status: .inReview,
      reviewClaim: ReviewClaim(reviewers: [
        ReviewerEntry(
          reviewerAgentId: "reviewer-codex",
          reviewerRuntime: "codex",
          claimedAt: "2026-05-14T10:00:00Z"
        ),
        ReviewerEntry(
          reviewerAgentId: "reviewer-claude",
          reviewerRuntime: "claude",
          claimedAt: "2026-05-14T10:01:00Z"
        ),
      ])
    )
    let agents = [
      makeAgent("reviewer-codex", runtime: "codex", role: .reviewer),
      makeAgent("reviewer-claude", runtime: "claude", role: .reviewer, status: .disconnected),
      makeAgent("reviewer-gemini", runtime: "gemini", role: .reviewer),
    ]

    #expect(
      TaskActionsSheet.eligibleReviewSubmitAgents(task: task, agents: agents).map(\.agentId)
        == ["reviewer-codex"]
    )
  }

  @Test("Review actors resolve to worker and leader identities")
  func reviewActorsResolveToWorkerAndLeaderIdentities() {
    let agents = [
      makeAgent("leader", runtime: "claude", role: .leader),
      makeAgent("worker", runtime: "codex", role: .worker, status: .awaitingReview),
    ]
    let inProgress = makeTask(status: .inProgress, assignedTo: "worker")
    let inReview = makeTask(
      status: .inReview,
      awaitingReview: AwaitingReview(
        queuedAt: "2026-05-14T10:00:00Z",
        submitterAgentId: "worker"
      ),
      consensus: ReviewConsensus(
        verdict: .requestChanges,
        summary: "Needs work",
        points: [ReviewPoint(pointId: "point-1", text: "Fix it")],
        closedAt: "2026-05-14T10:10:00Z"
      )
    )
    let arbitration = makeTask(
      status: .blocked,
      blockedReason: "awaiting_arbitration",
      reviewRound: 3
    )

    #expect(TaskActionsSheet.submitForReviewActorID(for: inProgress, agents: agents) == "worker")
    #expect(TaskActionsSheet.respondReviewActorID(for: inReview, agents: agents) == "worker")
    #expect(
      TaskActionsSheet.arbitrationActorID(
        for: arbitration,
        leaderID: "leader",
        agents: agents
      ) == "leader"
    )
  }
}

private func makeAgent(
  _ id: String,
  runtime: String = "codex",
  role: SessionRole,
  status: AgentStatus = .active,
  currentTaskID: String? = nil
) -> AgentRegistration {
  AgentRegistration(
    agentId: id,
    name: id,
    runtime: runtime,
    role: role,
    capabilities: [],
    joinedAt: "2026-05-14T09:00:00Z",
    updatedAt: "2026-05-14T09:00:00Z",
    status: status,
    agentSessionId: "\(id)-runtime",
    lastActivityAt: "2026-05-14T09:00:00Z",
    currentTaskId: currentTaskID,
    runtimeCapabilities: RuntimeCapabilities(
      runtime: runtime,
      supportsNativeTranscript: true,
      supportsSignalDelivery: true,
      supportsContextInjection: true,
      typicalSignalLatencySeconds: 1,
      hookPoints: []
    ),
    persona: nil
  )
}

private func makeTask(
  status: TaskStatus,
  assignedTo: String? = nil,
  blockedReason: String? = nil,
  awaitingReview: AwaitingReview? = nil,
  reviewClaim: ReviewClaim? = nil,
  consensus: ReviewConsensus? = nil,
  reviewRound: Int = 0
) -> WorkItem {
  WorkItem(
    taskId: "task-1",
    title: "Task",
    context: nil,
    severity: .medium,
    status: status,
    assignedTo: assignedTo,
    createdAt: "2026-05-14T09:00:00Z",
    updatedAt: "2026-05-14T09:00:00Z",
    createdBy: "leader",
    notes: [],
    suggestedFix: nil,
    source: .manual,
    blockedReason: blockedReason,
    completedAt: nil,
    checkpointSummary: nil,
    awaitingReview: awaitingReview,
    reviewClaim: reviewClaim,
    consensus: consensus,
    reviewRound: reviewRound
  )
}
