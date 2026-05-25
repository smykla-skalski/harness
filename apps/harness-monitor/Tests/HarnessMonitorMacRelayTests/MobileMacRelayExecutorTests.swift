import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorCrypto
import HarnessMonitorKit
import HarnessMonitorMacRelay
import XCTest

final class MobileMacRelayExecutorTests: XCTestCase {
  func testClientSnapshotSourceUsesSessionCheckoutAsReviewFallback() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let checkoutRoot = try makeGitHubCheckout(
      remoteURL: "https://token@example@github.com/smykla-skalski/harness.git"
    )
    let session = SessionSummary(
      projectId: "project",
      projectName: "Harness",
      projectDir: checkoutRoot.path,
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
      additions: 10,
      deletions: 1,
      createdAt: "2023-11-14T22:00:00Z",
      updatedAt: "2023-11-14T22:04:00Z"
    )
    let recorder = ReviewQueryRecorder()
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
          reviews: [review],
          reviewQueryRecorder: recorder
        )
      }
    )

    let snapshot = try await source.makeSnapshot(now: now)
    let requests = await recorder.requests()

    XCTAssertEqual(requests.map(\.repositories), [["smykla-skalski/harness"]])
    XCTAssertEqual(snapshot.reviews.map(\.repository), ["smykla-skalski/harness"])
    XCTAssertEqual(snapshot.needsYouCount, 1)
    XCTAssertFalse(snapshot.attention.contains { $0.id == "reviews-unavailable-station" })
  }

  func testAPIBackedExecutorDispatchesCommandFamilies() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = MobileDemoFixtures.snapshot(now: now)
    let client = RecordingMobileRelayCommandClient()
    let executor = HarnessMonitorClientMobileRelayCommandExecutor(
      client: client,
      now: { now }
    )

    _ = try await executor.execute(
      command(
        kind: .acpPermissionDecision,
        target: MobileCommandTarget(
          stationID: "station-mac-studio",
          agentID: "agent-codex-7",
          targetRevision: snapshot.revision
        ),
        payload: ["batchID": "batch-1", "decision": "approve_all"]
      ),
      snapshot: snapshot
    )
    _ = try await executor.execute(
      command(
        kind: .taskBoardDispatch,
        target: MobileCommandTarget(
          stationID: "station-mac-studio",
          taskID: "task-16",
          targetRevision: snapshot.revision
        ),
        payload: ["status": "todo", "dryRun": "false", "projectDir": "/repo"]
      ),
      snapshot: snapshot
    )
    _ = try await executor.execute(
      command(
        kind: .taskBoardPlanApproval,
        target: MobileCommandTarget(
          stationID: "station-mac-studio",
          taskID: "task-16",
          targetRevision: snapshot.revision
        ),
        payload: ["approvedBy": "watch"]
      ),
      snapshot: snapshot
    )
    _ = try await executor.execute(
      command(
        kind: .agentStart,
        target: MobileCommandTarget(
          stationID: "station-mac-studio",
          sessionID: "session-pr-review",
          taskID: "task-16",
          targetRevision: snapshot.revision
        ),
        payload: ["agent": "codex", "prompt": "Pick up the task", "role": "worker"]
      ),
      snapshot: snapshot
    )
    _ = try await executor.execute(
      command(
        kind: .agentPrompt,
        target: MobileCommandTarget(
          stationID: "station-mac-studio",
          agentID: "agent-codex-7",
          targetRevision: snapshot.revision
        ),
        payload: ["prompt": "Please summarize status."]
      ),
      snapshot: snapshot
    )
    _ = try await executor.execute(
      command(
        kind: .agentStop,
        target: MobileCommandTarget(
          stationID: "station-mac-studio",
          agentID: "agent-codex-7",
          targetRevision: snapshot.revision
        )
      ),
      snapshot: snapshot
    )
    _ = try await executor.execute(
      command(
        kind: .pullRequestMerge,
        target: MobileCommandTarget(
          stationID: "station-mac-studio",
          reviewID: "review-812",
          targetRevision: snapshot.revision
        ),
        payload: ["method": "squash", "headSha": "abc123"]
      ),
      snapshot: snapshot
    )
    _ = try await executor.execute(
      command(
        kind: .pullRequestLabel,
        target: MobileCommandTarget(
          stationID: "station-mac-studio",
          reviewID: "review-812",
          targetRevision: snapshot.revision
        ),
        payload: ["label": "ready"]
      ),
      snapshot: snapshot
    )
    _ = try await executor.execute(
      command(
        kind: .pullRequestRerunChecks,
        target: MobileCommandTarget(
          stationID: "station-mac-studio",
          reviewID: "review-812",
          targetRevision: snapshot.revision
        )
      ),
      snapshot: snapshot
    )
    _ = try await executor.execute(
      command(
        kind: .pullRequestApprove,
        target: MobileCommandTarget(
          stationID: "station-mac-studio",
          reviewID: "review-812",
          targetRevision: snapshot.revision
        )
      ),
      snapshot: snapshot
    )
    _ = try await executor.execute(
      command(
        kind: .refresh,
        target: MobileCommandTarget(
          stationID: "station-mac-studio",
          reviewID: "review-812",
          targetRevision: snapshot.revision
        ),
        payload: ["scope": "reviews"]
      ),
      snapshot: snapshot
    )
    _ = try await executor.execute(
      command(
        kind: .refresh,
        target: MobileCommandTarget(
          stationID: "station-mac-studio",
          targetRevision: snapshot.revision
        ),
        payload: ["scope": "reviews"]
      ),
      snapshot: snapshot
    )
    _ = try await executor.execute(
      command(
        kind: .refresh,
        target: MobileCommandTarget(
          stationID: "station-mac-studio",
          targetRevision: snapshot.revision
        ),
        payload: ["scope": "mobileMirror"]
      ),
      snapshot: snapshot
    )
    _ = try await executor.execute(
      command(
        kind: .refresh,
        target: MobileCommandTarget(
          stationID: "station-mac-studio",
          targetRevision: snapshot.revision
        ),
        payload: ["scope": "taskBoard"]
      ),
      snapshot: snapshot
    )
    _ = try await executor.execute(
      command(
        kind: .refresh,
        target: MobileCommandTarget(
          stationID: "station-mac-studio",
          sessionID: "session-pr-review",
          taskID: "task-16",
          targetRevision: snapshot.revision
        ),
        payload: ["scope": "sessionTasks"]
      ),
      snapshot: snapshot
    )

    let events = await client.events()
    XCTAssertEqual(
      events,
      [
        "acp:agent-codex-7:batch-1:approveAll",
        "dispatch:task-16:todo:false:/repo",
        "approve-plan:task-16:watch",
        "start-agent:session-pr-review:codex:codex:Pick up the task",
        "prompt-agent:agent-codex-7:Please summarize status.",
        "stop-agent:agent-codex-7",
        "merge-pr:smykla-skalski/harness#812:squash:abc123",
        "label-pr:smykla-skalski/harness#812:ready",
        "rerun-pr:smykla-skalski/harness#812",
        "approve-pr:smykla-skalski/harness#812",
        "refresh-reviews:smykla-skalski/harness#812",
        "refresh-reviews:none",
        "refresh-mobile-mirror",
        "refresh-task-board",
        "refresh-session-tasks:session-pr-review:task-16",
      ]
    )
  }

  func testAPIBackedExecutorRejectsUnknownRefreshScope() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = MobileDemoFixtures.snapshot(now: now)
    let client = RecordingMobileRelayCommandClient()
    let executor = HarnessMonitorClientMobileRelayCommandExecutor(
      client: client,
      now: { now }
    )

    do {
      _ = try await executor.execute(
        command(
          kind: .refresh,
          target: MobileCommandTarget(
            stationID: "station-mac-studio",
            targetRevision: snapshot.revision
          ),
          payload: ["scope": "everything"]
        ),
        snapshot: snapshot
      )
      XCTFail("Unknown refresh scope should fail before dispatch.")
    } catch {
      XCTAssertEqual(
        error as? MobileRelayCommandExecutionError,
        .invalidPayload(key: "scope", value: "everything")
      )
    }

    let events = await client.events()
    XCTAssertEqual(events, [])
  }

  func testAPIBackedCommandClientRefreshesStationReviewsWithoutTarget() async throws {
    let recorder = ReviewQueryRecorder()
    let request = ReviewsQueryRequest(
      repositories: ["smykla-skalski/harness"],
      forceRefresh: true,
      cacheMaxAgeSeconds: MobileRelayReviewsQueryPreferences.minimumCacheMaxAgeSeconds
    )
    let client = HarnessMonitorClientMobileRelayCommandClient(
      client: PreviewHarnessClient(),
      reviewsQueryProvider: {
        await recorder.record(request)
        return request
      }
    )

    let message = try await client.refreshReviews(nil as ReviewTarget?)
    let requests = await recorder.requests()

    XCTAssertTrue(message.hasPrefix("Refreshed "))
    XCTAssertEqual(requests, [request])
  }

  func testAPIBackedExecutorClassifiesAgentStartFamilies() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = MobileDemoFixtures.snapshot(now: now)
    let client = RecordingMobileRelayCommandClient()
    let executor = HarnessMonitorClientMobileRelayCommandExecutor(
      client: client,
      now: { now }
    )
    let target = MobileCommandTarget(
      stationID: "station-mac-studio",
      sessionID: "session-pr-review",
      targetRevision: snapshot.revision
    )

    _ = try await executor.execute(
      command(
        kind: .agentStart,
        target: target,
        payload: ["agent": "codex", "prompt": "Continue implementation"]
      ),
      snapshot: snapshot
    )
    _ = try await executor.execute(
      command(
        kind: .agentStart,
        target: target,
        payload: ["agent": "claude", "prompt": "Review the changes"]
      ),
      snapshot: snapshot
    )
    _ = try await executor.execute(
      command(
        kind: .agentStart,
        target: target,
        payload: ["agent": "acp:openrouter", "prompt": "Run model review"]
      ),
      snapshot: snapshot
    )

    let events = await client.events()
    XCTAssertEqual(
      events,
      [
        "start-agent:session-pr-review:codex:codex:Continue implementation",
        "start-agent:session-pr-review:terminal:claude:Review the changes",
        "start-agent:session-pr-review:acp:acp:openrouter:Run model review",
      ]
    )
  }
}
