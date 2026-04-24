import Foundation

extension PreviewFixtures {
  public enum ReviewFlow {
    public static let awaitingReviewTask = WorkItem(
      taskId: "task-review-queue",
      title: "Auth middleware review",
      context: "Queued after worker finished patch.",
      severity: .high,
      status: .awaitingReview,
      assignedTo: "worker-codex",
      queuePolicy: .locked,
      queuedAt: "2026-04-24T10:00:00Z",
      createdAt: "2026-04-24T09:30:00Z",
      updatedAt: "2026-04-24T10:00:00Z",
      createdBy: "leader-claude",
      notes: [],
      suggestedFix: nil,
      source: .manual,
      blockedReason: nil,
      completedAt: nil,
      checkpointSummary: nil,
      awaitingReview: AwaitingReview(
        queuedAt: "2026-04-24T10:00:00Z",
        submitterAgentId: "worker-codex",
        summary: "Patch ready; requires security review.",
        requiredConsensus: 2
      ),
      suggestedPersona: "reviewer-security"
    )

    public static let underReviewPartialClaimTask = WorkItem(
      taskId: "task-review-partial",
      title: "Upgrade quorum state machine",
      context: nil,
      severity: .medium,
      status: .inReview,
      assignedTo: "worker-codex",
      queuedAt: "2026-04-24T10:05:00Z",
      createdAt: "2026-04-24T09:40:00Z",
      updatedAt: "2026-04-24T10:12:00Z",
      createdBy: "leader-claude",
      notes: [],
      suggestedFix: nil,
      source: .manual,
      blockedReason: nil,
      completedAt: nil,
      checkpointSummary: nil,
      awaitingReview: AwaitingReview(
        queuedAt: "2026-04-24T10:05:00Z",
        submitterAgentId: "worker-codex",
        summary: "Partial claim: one reviewer online.",
        requiredConsensus: 2
      ),
      reviewClaim: ReviewClaim(reviewers: [
        ReviewerEntry(
          reviewerAgentId: "reviewer-claude",
          reviewerRuntime: "claude",
          claimedAt: "2026-04-24T10:08:00Z",
          submittedAt: nil
        )
      ]),
      reviewRound: 1
    )

    public static let consensusApprovedTask = WorkItem(
      taskId: "task-review-approved",
      title: "Ship improver rollback coverage",
      context: nil,
      severity: .low,
      status: .done,
      assignedTo: "worker-codex",
      createdAt: "2026-04-23T11:00:00Z",
      updatedAt: "2026-04-24T09:00:00Z",
      createdBy: "leader-claude",
      notes: [],
      suggestedFix: nil,
      source: .manual,
      blockedReason: nil,
      completedAt: "2026-04-24T09:00:00Z",
      checkpointSummary: nil,
      consensus: ReviewConsensus(
        verdict: .approve,
        summary: "Two reviewers approved after round 1.",
        closedAt: "2026-04-24T09:00:00Z",
        reviewerAgentIds: ["reviewer-claude", "reviewer-codex"]
      ),
      reviewRound: 1
    )

    public static let arbitrationPendingTask = WorkItem(
      taskId: "task-review-arbitration",
      title: "Storage adapter arbitration",
      context: nil,
      severity: .high,
      status: .inReview,
      assignedTo: "worker-codex",
      createdAt: "2026-04-22T10:00:00Z",
      updatedAt: "2026-04-24T10:30:00Z",
      createdBy: "leader-claude",
      notes: [],
      suggestedFix: nil,
      source: .manual,
      blockedReason: "awaiting_arbitration",
      completedAt: nil,
      checkpointSummary: nil,
      reviewRound: 3
    )

    public static let arbitrationDoneTask = WorkItem(
      taskId: "task-review-arbitrated",
      title: "Queue fairness arbitration",
      context: nil,
      severity: .high,
      status: .done,
      assignedTo: "worker-codex",
      createdAt: "2026-04-20T10:00:00Z",
      updatedAt: "2026-04-24T10:45:00Z",
      createdBy: "leader-claude",
      notes: [],
      suggestedFix: nil,
      source: .manual,
      blockedReason: nil,
      completedAt: "2026-04-24T10:45:00Z",
      checkpointSummary: nil,
      reviewRound: 3,
      arbitration: ArbitrationOutcome(
        arbiterAgentId: "leader-claude",
        verdict: .approve,
        summary: "Leader approved after two inconclusive rounds.",
        recordedAt: "2026-04-24T10:45:00Z"
      )
    )

    public static let tasks: [WorkItem] = [
      awaitingReviewTask,
      underReviewPartialClaimTask,
      consensusApprovedTask,
      arbitrationPendingTask,
      arbitrationDoneTask,
    ]

    public static let awaitingReviewAgent = AgentRegistration(
      agentId: "worker-codex-awaiting",
      name: "Codex Worker (Review)",
      runtime: "codex",
      role: .worker,
      capabilities: ["general"],
      joinedAt: "2026-04-24T09:00:00Z",
      updatedAt: "2026-04-24T10:00:00Z",
      status: .awaitingReview,
      agentSessionId: "codex-session-review",
      lastActivityAt: "2026-04-24T10:00:00Z",
      currentTaskId: awaitingReviewTask.taskId,
      runtimeCapabilities: RuntimeCapabilities(
        runtime: "codex",
        supportsNativeTranscript: true,
        supportsSignalDelivery: true,
        supportsContextInjection: true,
        typicalSignalLatencySeconds: 2,
        hookPoints: []
      ),
      persona: nil
    )

    public static let autoSpawnedReviewer = AgentRegistration(
      agentId: "reviewer-claude-auto",
      name: "Auto Reviewer",
      runtime: "claude",
      role: .reviewer,
      capabilities: [AgentRegistration.autoSpawnedCapability],
      joinedAt: "2026-04-24T10:02:00Z",
      updatedAt: "2026-04-24T10:02:00Z",
      status: .active,
      agentSessionId: "claude-session-auto",
      lastActivityAt: "2026-04-24T10:02:00Z",
      currentTaskId: nil,
      runtimeCapabilities: RuntimeCapabilities(
        runtime: "claude",
        supportsNativeTranscript: true,
        supportsSignalDelivery: true,
        supportsContextInjection: true,
        typicalSignalLatencySeconds: 3,
        hookPoints: []
      ),
      persona: nil
    )
  }
}
