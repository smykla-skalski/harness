import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorCrypto
import HarnessMonitorKit
import HarnessMonitorMacRelay
import XCTest

final class MobileMacRelaySnapshotSourceRedactTests: XCTestCase {
  func testClientSnapshotSourceRedactsSecretLikeValuesBeforeMirroring() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let source = makeRedactionSnapshotSource()

    let snapshot = try await source.makeSnapshot(now: now)
    let jsonData = try JSONEncoder().encode(snapshot)
    let json = try XCTUnwrap(String(data: jsonData, encoding: .utf8))

    for forbidden in [
      "stationsecret",
      "hunter2",
      "ghp_123456",
      "sk-abcdefghijklmnopqrstuvwxyz123456",
      "abcdefghijklmnopqrstuvwxyz1234567890",
      "github_pat_",
      "projectsecret",
      "refreshsecret",
      "authorpass",
      "labelsecret",
      "checksecret",
      "ci-password",
      "failedsecret",
      "filesecret",
      "commitsecret",
      "tasktokensecret",
      "taskbodysecret",
      "tagsecret",
      "tasksummarysecret",
    ] {
      XCTAssertFalse(json.contains(forbidden), "Mobile mirror leaked \(forbidden)")
    }
    XCTAssertTrue(json.contains("[redacted]"))
    XCTAssertEqual(snapshot.stations.first?.displayName, "Studio password=[redacted]")
    XCTAssertEqual(snapshot.sessions.first?.projectName, "Harness password=[redacted]")
    XCTAssertTrue(snapshot.sessions.first?.branch.contains("GH_TOKEN=[redacted]") == true)
    XCTAssertEqual(snapshot.sessions.first?.summary, "Bearer [redacted]")
    XCTAssertTrue(snapshot.sessions.first?.agents.first?.displayName.contains("[redacted]") == true)
    XCTAssertTrue(snapshot.reviews.first?.title.contains("[redacted]") == true)
    XCTAssertEqual(snapshot.reviews.first?.repository, "smykla-skalski/harness")
    XCTAssertTrue(snapshot.reviews.first?.files.first?.path.contains("[redacted]") == true)
    XCTAssertTrue(snapshot.reviews.first?.activity.first?.summary.contains("[redacted]") == true)
    XCTAssertTrue(snapshot.taskBoardItems.first?.title.contains("[redacted]") == true)
    XCTAssertTrue(snapshot.taskBoardItems.first?.bodyPreview.contains("[redacted]") == true)

    let reviewAttention = try XCTUnwrap(
      snapshot.attention.first { $0.kind == MobileAttentionKind.pullRequest }
    )
    XCTAssertEqual(reviewAttention.commandPayload["repository"], "smykla-skalski/harness")
    XCTAssertEqual(reviewAttention.commandPayload["headSha"], "abc123")
  }

  func testClientSnapshotSourceMirrorsSessionTasksIntoNeedsYou() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let session = SessionSummary(
      projectId: "project",
      projectName: "Harness",
      sessionId: "session-1",
      branchRef: "main",
      title: "Mobile relay",
      context: "Shipping the mobile relay.",
      status: .active,
      createdAt: "2023-11-14T22:00:00Z",
      updatedAt: "2023-11-14T22:01:00Z",
      lastActivityAt: "2023-11-14T22:02:00Z",
      leaderId: nil,
      observeId: nil,
      pendingLeaderTransfer: nil,
      metrics: SessionMetrics(activeAgentCount: 1)
    )
    let reviewTask = workItem(
      id: "task-review",
      title: "Review mobile relay",
      context: "Check the live mobile mirror before the worker continues.",
      severity: .high,
      status: .awaitingReview,
      updatedAt: "2023-11-14T22:03:00Z"
    )
    let blockedTask = workItem(
      id: "task-blocked",
      title: "Unblock phone sync",
      context: "The phone cannot see actionable items.",
      severity: .critical,
      status: .blocked,
      blockedReason: "Needs a relay data-path fix.",
      updatedAt: "2023-11-14T22:04:00Z"
    )
    let detail = SessionDetail(
      session: session,
      agents: [],
      tasks: [reviewTask, blockedTask],
      signals: [],
      observer: nil,
      agentActivity: []
    )
    let source = HarnessMonitorClientMobileMirrorSnapshotSource(
      stationID: "station",
      stationName: "Studio",
      clientProvider: {
        FixedMobileMirrorClient(
          health: HealthResponse(
            status: "ok",
            version: "1.0.0",
            pid: 1,
            endpoint: "http://127.0.0.1:1",
            startedAt: "2023-11-14T22:00:00Z",
            projectCount: 1,
            sessionCount: 1
          ),
          sessions: [session],
          agents: [session.sessionId: []],
          details: [session.sessionId: detail],
          reviews: []
        )
      }
    )

    let snapshot = try await source.makeSnapshot(now: now)
    let reviewAttention = try XCTUnwrap(
      snapshot.attention.first { $0.id == "session-task-session-1-task-review" }
    )
    let blockedAttention = try XCTUnwrap(
      snapshot.attention.first { $0.id == "session-task-session-1-task-blocked" }
    )

    XCTAssertEqual(snapshot.needsYouCount, 2)
    XCTAssertEqual(reviewAttention.title, "Task awaiting review")
    XCTAssertEqual(reviewAttention.commandPayload["scope"], "sessionTasks")
    XCTAssertEqual(reviewAttention.target?.sessionID, session.sessionId)
    XCTAssertEqual(reviewAttention.target?.taskID, reviewTask.taskId)
    XCTAssertEqual(blockedAttention.title, "Task is blocked")
    XCTAssertEqual(blockedAttention.severity, .critical)
    XCTAssertTrue(blockedAttention.subtitle.contains("Needs a relay data-path fix."))
  }

  func testClientSnapshotSourcePreservesTaskBoardItemsWhenFetchFails() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let session = mobileMirrorSession()
    let taskBoardItems = [
      taskBoardItem(id: "task-plan", status: .agenticReview, priority: .high),
      taskBoardItem(id: "task-blocked", status: .failed, priority: .critical),
    ]
    let provider = MobileMirrorClientProviderBox(
      client: FixedMobileMirrorClient(
        health: mobileMirrorHealth(),
        sessions: [session],
        agents: [session.sessionId: []],
        reviews: [],
        taskBoardItemsFixture: taskBoardItems
      )
    )
    let source = HarnessMonitorClientMobileMirrorSnapshotSource(
      stationID: "station",
      stationName: "Studio",
      clientProvider: { await provider.client() }
    )

    let firstSnapshot = try await source.makeSnapshot(now: now)
    await provider.setClient(
      FixedMobileMirrorClient(
        health: mobileMirrorHealth(),
        sessions: [session],
        agents: [session.sessionId: []],
        reviews: [],
        taskBoardUnavailable: true
      )
    )
    let preservedSnapshot = try await source.makeSnapshot(now: now.addingTimeInterval(30))

    XCTAssertEqual(firstSnapshot.taskBoardItems.map(\.id), ["task-blocked", "task-plan"])
    XCTAssertEqual(preservedSnapshot.taskBoardItems.map(\.id), ["task-blocked", "task-plan"])
    XCTAssertTrue(
      preservedSnapshot.attention.contains { $0.id == "task-board-plan-task-plan" }
    )
    XCTAssertTrue(
      preservedSnapshot.attention.contains { $0.id == "task-board-blocked-task-blocked" }
    )
    XCTAssertTrue(
      preservedSnapshot.attention.contains { $0.id == "task-board-unavailable-station" }
    )
    XCTAssertGreaterThanOrEqual(preservedSnapshot.needsYouCount, firstSnapshot.needsYouCount)
    XCTAssertEqual(preservedSnapshot.stations.first?.needsYouCount, preservedSnapshot.needsYouCount)
  }

  private func makeRedactionSnapshotSource() -> HarnessMonitorClientMobileMirrorSnapshotSource {
    let session = SessionSummary(
      projectId: "project",
      projectName: "Harness password=hunter2",
      sessionId: "session-1",
      branchRef: "feature/GH_TOKEN=ghp_123456789012345678901234567890123456",
      title: "Fix OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwxyz123456",
      context: "Bearer abcdefghijklmnopqrstuvwxyz1234567890",
      status: .active,
      createdAt: "2023-11-14T22:00:00Z",
      updatedAt: "2023-11-14T22:01:00Z",
      lastActivityAt: "2023-11-14T22:02:00Z",
      leaderId: nil,
      observeId: nil,
      pendingLeaderTransfer: nil,
      metrics: SessionMetrics(activeAgentCount: 1)
    )
    let secretTask = workItem(
      id: "task-secret",
      title: "Review AWS_SECRET_ACCESS_KEY=AKIAABCDEFGHIJKLMNOP",
      context: "client_secret=tasksecret",
      severity: .critical,
      status: .blocked,
      blockedReason: "refresh_token=refreshsecret",
      updatedAt: "2023-11-14T22:04:00Z"
    )
    let detail = SessionDetail(
      session: session,
      agents: [],
      tasks: [secretTask],
      signals: [],
      observer: nil,
      agentActivity: []
    )
    let codexAgent = makeRedactionCodexAgent(sessionID: session.sessionId)
    let review = makeRedactionReview()
    let reviewFiles = makeRedactionReviewFiles(for: review)
    let reviewTimeline = makeRedactionReviewTimeline(for: review)
    let taskBoardItem = makeRedactionTaskBoardItem(
      sessionID: session.sessionId,
      workItemID: secretTask.taskId
    )
    return HarnessMonitorClientMobileMirrorSnapshotSource(
      stationID: "station",
      stationName: "Studio password=stationsecret",
      clientProvider: {
        FixedMobileMirrorClient(
          health: mobileMirrorHealth(),
          sessions: [session],
          agents: [session.sessionId: [codexAgent]],
          details: [session.sessionId: detail],
          reviews: [review],
          reviewFiles: [review.pullRequestID: reviewFiles],
          reviewTimelines: [review.pullRequestID: reviewTimeline],
          taskBoardItemsFixture: [taskBoardItem]
        )
      },
      reviewsQueryProvider: {
        ReviewsQueryRequest(
          repositories: ["smykla-skalski/harness"],
          cacheMaxAgeSeconds: 60
        )
      }
    )
  }

  private func makeRedactionCodexAgent(sessionID: String) -> ManagedAgentSnapshot {
    ManagedAgentSnapshot.codex(
      CodexRunSnapshot(
        runId: "codex-1",
        sessionId: sessionID,
        displayName: "Codex github_pat_ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890",
        projectDir: "/tmp/password=projectsecret",
        threadId: nil,
        turnId: nil,
        mode: .workspaceWrite,
        status: .waitingApproval,
        prompt: "ANTHROPIC_API_KEY=sk-zyxwvutsrqponmlkjihgfedcba123456",
        latestSummary: "Posting Bearer zyxwvutsrqponmlkjihgfedcba123456",
        finalMessage: nil,
        error: "refresh_token=refreshsecret",
        pendingApprovals: [],
        createdAt: "2023-11-14T22:00:00Z",
        updatedAt: "2023-11-14T22:05:00Z"
      )
    )
  }

  private func makeRedactionReview() -> ReviewItem {
    ReviewItem(
      pullRequestID: "review-1",
      repositoryID: "repo-1",
      repository: "smykla-skalski/harness",
      number: 812,
      title: "Rotate github_pat_ZYXWVUTSRQPONMLKJIHGFEDCBA123456",
      url: "https://user:pass@example.com/smykla-skalski/harness/pull/812",
      authorLogin: "bot secret=authorpass",
      state: .open,
      mergeable: .mergeable,
      reviewStatus: .reviewRequired,
      checkStatus: .failure,
      policyBlocked: false,
      isDraft: false,
      headSha: "abc123",
      labels: ["api_key=labelsecret"],
      checks: [
        ReviewCheck(
          name: "CI password=checksecret",
          status: .completed,
          conclusion: .failure,
          checkSuiteID: "suite-mobile",
          detailsURL: "https://ci-user:ci-password@example.com/mobile"
        )
      ],
      additions: 10,
      deletions: 1,
      createdAt: "2023-11-14T22:00:00Z",
      updatedAt: "2023-11-14T22:04:00Z",
      requiredFailedCheckNames: ["OPENAI_API_KEY=failedsecret"]
    )
  }

  private func makeRedactionReviewFiles(for review: ReviewItem) -> ReviewsFilesListResponse {
    ReviewsFilesListResponse(
      pullRequestID: review.pullRequestID,
      number: review.number,
      headRefOid: review.headSha,
      repositoryFullName: review.repository,
      viewerCanMarkViewed: true,
      files: [
        ReviewFile(path: "config/password=filesecret.env")
      ],
      fetchedAt: "2023-11-14T22:05:00Z",
      paginationComplete: true
    )
  }

  private func makeRedactionReviewTimeline(for review: ReviewItem) -> ReviewsTimelineResponse {
    ReviewsTimelineResponse(
      pullRequestId: review.pullRequestID,
      entries: [
        .commit(
          CommitPayload(
            id: "timeline-commit-1",
            createdAt: "2023-11-14T22:05:00Z",
            oid: "abcdef123456",
            abbreviatedOid: "abcdef1",
            messageHeadline: "AWS_SECRET_ACCESS_KEY=commitsecret"
          )
        )
      ],
      pageInfo: ReviewTimelinePageInfo(),
      viewerCanComment: true,
      fetchedAt: "2023-11-14T22:05:30Z"
    )
  }

  private func makeRedactionTaskBoardItem(sessionID: String, workItemID: String) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: "task-board-secret",
      title: "Dispatch github_token=tasktokensecret",
      body: "password=taskbodysecret",
      status: .humanRequired,
      priority: .critical,
      tags: ["client_secret=tagsecret"],
      projectId: "project-secret=projectsecret",
      agentMode: .planning,
      externalRefs: [],
      planning: TaskBoardPlanningState(summary: "OPENAI_API_KEY=tasksummarysecret"),
      workflow: nil,
      sessionId: sessionID,
      workItemId: workItemID,
      usage: TaskBoardUsage(),
      createdAt: "2023-11-14T22:00:00Z",
      updatedAt: "2023-11-14T22:06:00Z",
      deletedAt: nil
    )
  }
}
