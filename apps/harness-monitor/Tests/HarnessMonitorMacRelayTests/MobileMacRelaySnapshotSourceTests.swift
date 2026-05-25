import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorCrypto
import HarnessMonitorKit
import HarnessMonitorMacRelay
import XCTest

final class MobileMacRelaySnapshotSourceTests: XCTestCase {
  func testClientSnapshotSourceMirrorsLiveStateAndCommandPayloads() async throws {
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
    let acpAgent = ManagedAgentSnapshot.acp(
      AcpAgentSnapshot(
        acpId: "acp-1",
        sessionId: session.sessionId,
        agentId: "agent-1",
        displayName: "Codex",
        status: .active,
        pid: 123,
        pgid: 123,
        projectDir: "/repo",
        pendingPermissions: 1,
        permissionQueueDepth: 1,
        pendingPermissionBatches: [
          AcpPermissionBatch(
            batchId: "batch-1",
            acpId: "acp-1",
            sessionId: session.sessionId,
            requests: [],
            createdAt: "2023-11-14T22:03:00Z"
          )
        ],
        terminalCount: 0,
        createdAt: "2023-11-14T22:00:00Z",
        updatedAt: "2023-11-14T22:03:00Z"
      )
    )
    let review = ReviewItem(
      pullRequestID: "review-1",
      repositoryID: "repo-1",
      repository: "smykla-skalski/harness",
      number: 812,
      title: "Add mobile relay",
      url: "https://github.com/smykla-skalski/harness/pull/812",
      authorLogin: "codex",
      state: .open,
      mergeable: .mergeable,
      reviewStatus: .reviewRequired,
      checkStatus: .success,
      policyBlocked: false,
      isDraft: false,
      headSha: "abc123",
      labels: ["mobile", "needs-review"],
      checks: [
        ReviewCheck(
          name: "HarnessMonitorMobileTests",
          status: .completed,
          conclusion: .success,
          checkSuiteID: "suite-mobile",
          detailsURL: "https://ci.example/mobile"
        )
      ],
      additions: 10,
      deletions: 1,
      createdAt: "2023-11-14T22:00:00Z",
      updatedAt: "2023-11-14T22:04:00Z",
      requiredFailedCheckNames: ["HarnessMonitorMobileTests"]
    )
    let reviewFiles = ReviewsFilesListResponse(
      pullRequestID: review.pullRequestID,
      number: review.number,
      headRefOid: review.headSha,
      repositoryFullName: review.repository,
      viewerCanMarkViewed: true,
      files: [
        ReviewFile(
          path: "Sources/HarnessMonitorMobile/MobileReviewsView.swift",
          changeType: .modified,
          additions: 12,
          deletions: 3,
          viewerViewedState: .unviewed,
          languageHint: .swift
        )
      ],
      fetchedAt: "2023-11-14T22:05:00Z",
      paginationComplete: true
    )
    let reviewTimeline = ReviewsTimelineResponse(
      pullRequestId: review.pullRequestID,
      entries: [
        .review(
          ReviewPayload(
            id: "timeline-review-1",
            createdAt: "2023-11-14T22:05:00Z",
            actor: ReviewTimelineActor(login: "bart"),
            state: .approved
          )
        )
      ],
      pageInfo: ReviewTimelinePageInfo(),
      viewerCanComment: true,
      fetchedAt: "2023-11-14T22:05:30Z"
    )
    let taskBoardItem = TaskBoardItem(
      schemaVersion: 1,
      id: "task-1",
      title: "Approve the mobile plan",
      body: "Review the implementation plan before the agent continues.",
      status: .planReview,
      priority: .high,
      tags: ["mobile"],
      projectId: "project",
      agentMode: .planning,
      externalRefs: [],
      planning: TaskBoardPlanningState(summary: "Ready for review."),
      workflow: nil,
      sessionId: session.sessionId,
      workItemId: nil,
      usage: TaskBoardUsage(),
      createdAt: "2023-11-14T22:00:00Z",
      updatedAt: "2023-11-14T22:06:00Z",
      deletedAt: nil
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
          agents: [session.sessionId: [acpAgent]],
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
      },
      trustedDeviceProvider: {
        [
          MobileDeviceDescriptor(
            id: "device-phone",
            displayName: "Phone",
            publicKeyFingerprint: "AA:BB",
            pairedAt: now
          )
        ]
      }
    )

    let snapshot = try await source.makeSnapshot(now: now)
    let permission: MobileAttentionItem = try XCTUnwrap(
      snapshot.attention.first { $0.kind == MobileAttentionKind.acpDecision }
    )
    let reviewAttention: MobileAttentionItem = try XCTUnwrap(
      snapshot.attention.first { $0.kind == MobileAttentionKind.pullRequest }
    )
    let taskBoardAttention: MobileAttentionItem = try XCTUnwrap(
      snapshot.attention.first { $0.kind == MobileAttentionKind.taskBoard }
    )

    XCTAssertEqual(snapshot.stations.first?.state, .online)
    XCTAssertEqual(snapshot.sessions.first?.activeAgentCount, 1)
    XCTAssertEqual(snapshot.sessions.first?.agents.first?.pendingPermissionCount, 1)
    XCTAssertEqual(permission.commandPayload["batchID"], "batch-1")
    XCTAssertEqual(permission.commandPayload["decision"], "approve_all")
    XCTAssertEqual(reviewAttention.commandPayload["repository"], "smykla-skalski/harness")
    XCTAssertEqual(taskBoardAttention.commandKind, .taskBoardPlanApproval)
    XCTAssertEqual(taskBoardAttention.target?.taskID, "task-1")
    XCTAssertEqual(snapshot.taskBoardItems.first?.id, "task-1")
    XCTAssertEqual(snapshot.taskBoardItems.first?.title, "Approve the mobile plan")
    XCTAssertEqual(snapshot.taskBoardItems.first?.statusTitle, "Plan Review")
    XCTAssertEqual(snapshot.taskBoardItems.first?.priorityTitle, "High")
    XCTAssertEqual(snapshot.taskBoardItems.first?.needsYou, true)
    XCTAssertEqual(snapshot.reviews.first?.labels, ["mobile", "needs-review"])
    XCTAssertEqual(snapshot.reviews.first?.checks.first?.checkSuiteID, "suite-mobile")
    XCTAssertEqual(
      snapshot.reviews.first?.files.first?.path,
      "Sources/HarnessMonitorMobile/MobileReviewsView.swift"
    )
    XCTAssertEqual(snapshot.reviews.first?.activity.first?.summary, "Review approved")
    XCTAssertEqual(snapshot.reviews.first?.requiredFailedCheckNames, ["HarnessMonitorMobileTests"])
    XCTAssertEqual(snapshot.needsYouCount, 3)
    XCTAssertEqual(snapshot.stations.first?.needsYouCount, snapshot.needsYouCount)
    XCTAssertEqual(snapshot.trustedDevices.first?.id, "device-phone")
  }

  func testClientSnapshotSourceBoundsReviewDetailEnrichment() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let session = mobileMirrorSession()
    let reviews = (0..<30).map { index in
      reviewItem(
        pullRequestID: "review-\(index)",
        number: UInt64(800 + index),
        updatedAt: String(format: "2023-11-14T22:05:%02dZ", index)
      )
    }
    let recorder = ReviewDetailRecorder()
    let source = HarnessMonitorClientMobileMirrorSnapshotSource(
      stationID: "station",
      stationName: "Studio",
      clientProvider: {
        FixedMobileMirrorClient(
          health: mobileMirrorHealth(),
          sessions: [session],
          agents: [session.sessionId: []],
          reviews: reviews,
          reviewDetailRecorder: recorder
        )
      },
      reviewsQueryProvider: {
        ReviewsQueryRequest(
          repositories: ["smykla-skalski/harness"],
          cacheMaxAgeSeconds: 60
        )
      }
    )

    let snapshot = try await source.makeSnapshot(now: now)
    let fileRequestIDs = await recorder.fileRequestIDs()
    let timelineRequestIDs = await recorder.timelineRequestIDs()

    XCTAssertEqual(snapshot.reviews.count, 30)
    XCTAssertEqual(Set(fileRequestIDs).count, 24)
    XCTAssertEqual(Set(timelineRequestIDs).count, 24)
    XCTAssertTrue(fileRequestIDs.contains("review-29"))
    XCTAssertFalse(fileRequestIDs.contains("review-0"))
  }
}
