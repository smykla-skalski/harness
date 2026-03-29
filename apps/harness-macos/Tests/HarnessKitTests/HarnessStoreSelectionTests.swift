import Observation
import XCTest

@testable import HarnessKit

@MainActor
final class HarnessStoreSelectionTests: XCTestCase {
  func testRefreshDiagnosticsDoesNotClaimGlobalBusyState() async throws {
    let client = RecordingHarnessClient()
    client.configureDiagnosticsDelay(.milliseconds(150))
    let store = await makeBootstrappedStore(client: client)

    let refreshTask = Task {
      await store.refreshDiagnostics()
    }
    await Task.yield()

    XCTAssertTrue(store.isDiagnosticsRefreshInFlight)
    XCTAssertFalse(store.isBusy)
    XCTAssertFalse(store.isDaemonActionInFlight)
    XCTAssertFalse(store.isSessionActionInFlight)

    await refreshTask.value

    XCTAssertFalse(store.isDiagnosticsRefreshInFlight)
  }

  func testLatestSessionSelectionWinsWhenOlderLoadCompletesLast() async throws {
    let firstSummary = makeSession(
      .init(
        sessionId: "sess-a",
        context: "First cockpit lane",
        status: .active,
        leaderId: "leader-a",
        observeId: "observe-a",
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      )
    )
    let secondSummary = makeSession(
      .init(
        sessionId: "sess-b",
        context: "Second cockpit lane",
        status: .active,
        leaderId: "leader-b",
        observeId: "observe-b",
        openTaskCount: 0,
        inProgressTaskCount: 1,
        blockedTaskCount: 0,
        activeAgentCount: 2
      )
    )
    let firstDetail = makeSessionDetail(
      summary: firstSummary,
      workerID: "worker-a",
      workerName: "Worker A"
    )
    let secondDetail = makeSessionDetail(
      summary: secondSummary,
      workerID: "worker-b",
      workerName: "Worker B"
    )
    let client = RecordingHarnessClient(detail: firstDetail)
    client.configureSessions(
      summaries: [firstSummary, secondSummary],
      detailsByID: [
        firstSummary.sessionId: firstDetail,
        secondSummary.sessionId: secondDetail,
      ],
      timelinesBySessionID: [
        firstSummary.sessionId: makeTimelineEntries(
          sessionID: firstSummary.sessionId,
          agentID: "worker-a",
          summary: "First timeline"
        ),
        secondSummary.sessionId: makeTimelineEntries(
          sessionID: secondSummary.sessionId,
          agentID: "worker-b",
          summary: "Second timeline"
        ),
      ]
    )
    client.configureDetailDelay(.milliseconds(250), for: firstSummary.sessionId)
    client.configureTimelineDelay(.milliseconds(250), for: firstSummary.sessionId)
    client.configureDetailDelay(.milliseconds(20), for: secondSummary.sessionId)
    client.configureTimelineDelay(.milliseconds(20), for: secondSummary.sessionId)
    let store = await makeBootstrappedStore(client: client)

    let firstSelection = Task {
      await store.selectSession(firstSummary.sessionId)
    }
    try await Task.sleep(for: .milliseconds(40))
    let secondSelection = Task {
      await store.selectSession(secondSummary.sessionId)
    }

    await secondSelection.value
    await firstSelection.value

    XCTAssertEqual(store.selectedSessionID, secondSummary.sessionId)
    XCTAssertEqual(store.selectedSession?.session.sessionId, secondSummary.sessionId)
    XCTAssertEqual(store.timeline.map(\.sessionId), [secondSummary.sessionId])
    XCTAssertEqual(store.timeline.map(\.summary), ["Second timeline"])
    XCTAssertEqual(store.actionActorID, secondSummary.leaderId)
    XCTAssertFalse(store.isSelectionLoading)
  }

  func testSelectedTaskObservationTracksInspectorSelectionChanges() async throws {
    let store = await makeBootstrappedStore()

    await store.selectSession(PreviewFixtures.summary.sessionId)

    let observationDidFire = expectation(description: "selected task observation fired")
    _ = withObservationTracking(
      {
        store.selectedTask?.taskId
      },
      onChange: {
        observationDidFire.fulfill()
      }
    )

    store.inspect(taskID: "task-ui")

    await fulfillment(of: [observationDidFire], timeout: 1)
    XCTAssertEqual(store.selectedTask?.taskId, "task-ui")
  }
}
