import Foundation

@testable import HarnessMonitorKit

@MainActor
extension TaskBoardSwiftUXCorrectnessTests {
  func sampleDraftDocument(revision: UInt64 = 7) -> PolicyPipelineDocument {
    PolicyPipelineDocument(
      schemaVersion: 2,
      revision: revision,
      mode: .draft,
      nodes: [],
      edges: [],
      groups: [],
      layout: PolicyPipelineLayout(),
      policyTraceIds: []
    )
  }

  func sampleTaskBoardItem(
    id: String = "board-1",
    status: TaskBoardStatus = .planning
  ) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: id,
      title: "Title",
      body: "Body",
      status: status,
      priority: .medium,
      tags: [],
      projectId: nil,
      agentMode: .headless,
      externalRefs: [],
      planning: TaskBoardPlanningState(),
      workflow: nil,
      sessionId: nil,
      workItemId: nil,
      usage: TaskBoardUsage(),
      createdAt: "2026-05-14T10:00:00Z",
      updatedAt: "2026-05-14T10:01:00Z",
      deletedAt: nil
    )
  }

  func sampleReview(
    checks: [ReviewCheck]
  ) -> ReviewItem {
    ReviewItem(
      pullRequestID: "pr-1",
      repositoryID: "repo-1",
      repository: "acme/api",
      number: 1,
      title: "Review",
      url: "https://github.com/acme/api/pull/1",
      authorLogin: "renovate[bot]",
      state: .open,
      mergeable: .mergeable,
      reviewStatus: .reviewRequired,
      checkStatus: .failure,
      policyBlocked: false,
      isDraft: false,
      headSha: "abc123",
      checks: checks,
      additions: 1,
      deletions: 0,
      createdAt: "2026-05-14T10:00:00Z",
      updatedAt: "2026-05-14T10:01:00Z"
    )
  }
}
