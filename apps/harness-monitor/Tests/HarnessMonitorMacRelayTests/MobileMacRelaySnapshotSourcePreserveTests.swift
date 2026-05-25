import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorCrypto
import HarnessMonitorKit
import HarnessMonitorMacRelay
import XCTest

final class MobileMacRelaySnapshotSourcePreserveTests: XCTestCase {
  func testClientSnapshotSourceDoesNotPublishEmptySnapshotBeforeFirstLiveMirror()
    async throws
  {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let source = HarnessMonitorClientMobileMirrorSnapshotSource(
      stationID: "station",
      stationName: "Studio",
      clientProvider: { nil }
    )

    do {
      _ = try await source.makeSnapshot(now: now)
      XCTFail("Expected the source to wait for a live mirror before publishing")
    } catch let error as MobileMirrorSnapshotUnavailable {
      XCTAssertEqual(
        error.message,
        "Mac relay is waiting for the Harness daemon connection."
      )
    }
  }

  func testClientSnapshotSourcePreservesLastMirrorWhenClientTemporarilyUnavailable()
    async throws
  {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let session = mobileMirrorSession()
    let provider = MobileMirrorClientProviderBox(
      client: FixedMobileMirrorClient(
        health: mobileMirrorHealth(),
        sessions: [session],
        agents: [session.sessionId: []],
        reviews: [],
        taskBoardItemsFixture: [
          taskBoardItem(id: "task-plan", status: .planReview, priority: .high)
        ]
      )
    )
    let source = HarnessMonitorClientMobileMirrorSnapshotSource(
      stationID: "station",
      stationName: "Studio",
      clientProvider: { await provider.client() }
    )

    let firstSnapshot = try await source.makeSnapshot(now: now)
    await provider.setClient(nil)
    let preservedSnapshot = try await source.makeSnapshot(now: now.addingTimeInterval(30))

    XCTAssertEqual(firstSnapshot.taskBoardItems.map(\.id), ["task-plan"])
    XCTAssertEqual(preservedSnapshot.taskBoardItems.map(\.id), ["task-plan"])
    XCTAssertTrue(preservedSnapshot.attention.contains { $0.id == "task-board-plan-task-plan" })
    XCTAssertTrue(preservedSnapshot.attention.contains { $0.id == "station-health-station" })
    XCTAssertEqual(preservedSnapshot.stations.first?.state, .stale)
    XCTAssertGreaterThanOrEqual(preservedSnapshot.needsYouCount, firstSnapshot.needsYouCount)
  }

  func testClientSnapshotSourcePreservesAgentAttentionWhenAgentRefreshFails() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let session = mobileMirrorSession()
    let agent = mobileMirrorAcpAgent(
      sessionID: session.sessionId,
      batchID: "batch-agent-stale"
    )
    let provider = MobileMirrorClientProviderBox(
      client: FixedMobileMirrorClient(
        health: mobileMirrorHealth(),
        sessions: [session],
        agents: [session.sessionId: [agent]],
        reviews: []
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
        agents: [:],
        reviews: [],
        unavailableManagedAgentSessionIDs: [session.sessionId]
      )
    )
    let preservedSnapshot = try await source.makeSnapshot(now: now.addingTimeInterval(30))

    XCTAssertTrue(firstSnapshot.attention.contains { $0.id == "acp-batch-agent-stale" })
    XCTAssertTrue(preservedSnapshot.attention.contains { $0.id == "acp-batch-agent-stale" })
    XCTAssertTrue(preservedSnapshot.attention.contains {
      $0.id == "managed-agents-unavailable-station"
    })
    XCTAssertEqual(
      preservedSnapshot.sessions.first?.agents.map(\.id),
      firstSnapshot.sessions.first?.agents.map(\.id)
    )
    XCTAssertGreaterThanOrEqual(preservedSnapshot.needsYouCount, firstSnapshot.needsYouCount)
    XCTAssertEqual(preservedSnapshot.stations.first?.needsYouCount, preservedSnapshot.needsYouCount)
  }

  func testClientSnapshotSourcePreservesSessionTaskAttentionWhenDetailRefreshFails()
    async throws
  {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let session = mobileMirrorSession()
    let reviewTask = workItem(
      id: "task-review",
      title: "Review mobile relay",
      context: "Check the live mobile mirror before the worker continues.",
      severity: .high,
      status: .awaitingReview,
      updatedAt: "2023-11-14T22:03:00Z"
    )
    let detail = SessionDetail(
      session: session,
      agents: [],
      tasks: [reviewTask],
      signals: [],
      observer: nil,
      agentActivity: []
    )
    let provider = MobileMirrorClientProviderBox(
      client: FixedMobileMirrorClient(
        health: mobileMirrorHealth(),
        sessions: [session],
        agents: [session.sessionId: []],
        details: [session.sessionId: detail],
        reviews: []
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
        unavailableSessionDetailIDs: [session.sessionId]
      )
    )
    let preservedSnapshot = try await source.makeSnapshot(now: now.addingTimeInterval(30))

    XCTAssertTrue(firstSnapshot.attention.contains {
      $0.id == "session-task-session-1-task-review"
    })
    XCTAssertTrue(preservedSnapshot.attention.contains {
      $0.id == "session-task-session-1-task-review"
    })
    XCTAssertTrue(preservedSnapshot.attention.contains {
      $0.id == "session-details-unavailable-station"
    })
    XCTAssertGreaterThanOrEqual(preservedSnapshot.needsYouCount, firstSnapshot.needsYouCount)
    XCTAssertEqual(preservedSnapshot.stations.first?.needsYouCount, preservedSnapshot.needsYouCount)
  }

  func testClientSnapshotSourcePreservesAttentionWhenRelayRefreshFails() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let session = mobileMirrorSession()
    let provider = MobileMirrorClientProviderBox(
      client: FixedMobileMirrorClient(
        health: mobileMirrorHealth(),
        sessions: [session],
        agents: [session.sessionId: []],
        reviews: [],
        taskBoardItemsFixture: [
          taskBoardItem(id: "task-plan", status: .planReview, priority: .high)
        ]
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
        healthUnavailable: true
      )
    )
    let preservedSnapshot = try await source.makeSnapshot(now: now.addingTimeInterval(30))

    XCTAssertTrue(preservedSnapshot.attention.contains { $0.id == "task-board-plan-task-plan" })
    XCTAssertTrue(preservedSnapshot.attention.contains { $0.id == "station-health-station" })
    XCTAssertEqual(preservedSnapshot.taskBoardItems.map(\.id), ["task-plan"])
    XCTAssertGreaterThanOrEqual(preservedSnapshot.needsYouCount, firstSnapshot.needsYouCount)
    XCTAssertEqual(preservedSnapshot.stations.first?.state, .stale)
    XCTAssertEqual(preservedSnapshot.stations.first?.needsYouCount, preservedSnapshot.needsYouCount)
  }

  func testClientSnapshotSourceRetriesTransientClientFailureAfterInvalidation()
    async throws
  {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let session = mobileMirrorSession()
    let provider = MobileMirrorClientProviderBox(
      client: FixedMobileMirrorClient(
        health: mobileMirrorHealth(),
        sessions: [session],
        agents: [session.sessionId: []],
        reviews: [],
        healthError: MobileRelayTransientTestError(message: "WebSocket connection closed")
      )
    )
    let handler = MobileRelayFailureHandlerProbe()
    let source = HarnessMonitorClientMobileMirrorSnapshotSource(
      stationID: "station",
      stationName: "Studio",
      clientProvider: { await provider.client() },
      clientFailureHandler: { reason in
        await handler.record(reason)
        await provider.setClient(
          FixedMobileMirrorClient(
            health: mobileMirrorHealth(),
            sessions: [session],
            agents: [session.sessionId: []],
            reviews: []
          )
        )
      }
    )

    let snapshot = try await source.makeSnapshot(now: now)
    let recordedFailures = await handler.recordedReasons()

    XCTAssertEqual(snapshot.stations.first?.state, .online)
    XCTAssertEqual(snapshot.sessions.map(\.id), [session.sessionId])
    XCTAssertEqual(recordedFailures.count, 1)
    XCTAssertTrue(recordedFailures.first?.contains("WebSocket connection closed") == true)
  }

  func testClientSnapshotSourceDefersShortTransientFailureInsteadOfPublishingStale()
    async throws
  {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let session = mobileMirrorSession()
    let provider = MobileMirrorClientProviderBox(
      client: FixedMobileMirrorClient(
        health: mobileMirrorHealth(),
        sessions: [session],
        agents: [session.sessionId: []],
        reviews: []
      )
    )
    let source = HarnessMonitorClientMobileMirrorSnapshotSource(
      stationID: "station",
      stationName: "Studio",
      clientProvider: { await provider.client() },
      transientUnavailableGrace: 60
    )

    let liveSnapshot = try await source.makeSnapshot(now: now)
    await provider.setClient(
      FixedMobileMirrorClient(
        health: mobileMirrorHealth(),
        sessions: [session],
        agents: [session.sessionId: []],
        reviews: [],
        healthError: MobileRelayTransientTestError(message: "WebSocket connection closed")
      )
    )

    do {
      _ = try await source.makeSnapshot(now: now.addingTimeInterval(5))
      XCTFail("Expected short transient daemon failures to skip CloudKit stale writes")
    } catch let error as MobileMirrorSnapshotUnavailable {
      XCTAssertTrue(error.message.contains("WebSocket connection closed"))
    }

    await provider.setClient(
      FixedMobileMirrorClient(
        health: mobileMirrorHealth(),
        sessions: [session],
        agents: [session.sessionId: []],
        reviews: []
      )
    )
    let recoveredSnapshot = try await source.makeSnapshot(now: now.addingTimeInterval(10))

    XCTAssertEqual(liveSnapshot.stations.first?.state, .online)
    XCTAssertEqual(recoveredSnapshot.stations.first?.state, .online)
    XCTAssertFalse(recoveredSnapshot.attention.contains { $0.id == "station-health-station" })
  }

  func testClientSnapshotSourcePreservesReviewsWhenRefreshFails() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let session = mobileMirrorSession()
    let review = reviewItem()
    let provider = MobileMirrorClientProviderBox(
      client: FixedMobileMirrorClient(
        health: mobileMirrorHealth(),
        sessions: [session],
        agents: [session.sessionId: []],
        reviews: [review]
      )
    )
    let source = HarnessMonitorClientMobileMirrorSnapshotSource(
      stationID: "station",
      stationName: "Studio",
      clientProvider: { await provider.client() },
      reviewsQueryProvider: {
        ReviewsQueryRequest(
          repositories: ["smykla-skalski/harness"],
          cacheMaxAgeSeconds: 60
        )
      }
    )

    let firstSnapshot = try await source.makeSnapshot(now: now)
    await provider.setClient(
      FixedMobileMirrorClient(
        health: mobileMirrorHealth(),
        sessions: [session],
        agents: [session.sessionId: []],
        reviews: [],
        reviewsUnavailable: true
      )
    )
    let preservedSnapshot = try await source.makeSnapshot(now: now.addingTimeInterval(30))

    XCTAssertEqual(firstSnapshot.reviews.map(\.id), ["review-1"])
    XCTAssertEqual(preservedSnapshot.reviews.map(\.id), ["review-1"])
    XCTAssertTrue(preservedSnapshot.attention.contains { $0.id == "review-review-1" })
    XCTAssertTrue(preservedSnapshot.attention.contains { $0.id == "reviews-unavailable-station" })
    XCTAssertGreaterThanOrEqual(preservedSnapshot.needsYouCount, firstSnapshot.needsYouCount)
    XCTAssertEqual(preservedSnapshot.stations.first?.needsYouCount, preservedSnapshot.needsYouCount)
  }
}
