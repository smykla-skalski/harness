import Foundation
import XCTest

@testable import HarnessMonitorKit

@MainActor
final class PersistedSnapshotHydrationTests: XCTestCase {
  func test_backgroundHydrationVisitsEveryUnhydratedSession() async throws {
    let sessions = (0..<64).map { index in
      makeSession(
        .init(
          sessionId: "sess-hydrate-\(index)",
          context: "Hydrate \(index)",
          status: .active,
          leaderId: "leader-hydrate-\(index)",
          observeId: nil,
          openTaskCount: 0,
          inProgressTaskCount: 0,
          blockedTaskCount: 0,
          activeAgentCount: 1
        )
      )
    }
    let details = Dictionary(
      uniqueKeysWithValues: sessions.map { summary in
        (
          summary.sessionId,
          makeSessionDetail(
            summary: summary,
            workerID: "worker-\(summary.sessionId)",
            workerName: "Worker"
          )
        )
      }
    )
    let timelines = Dictionary(
      uniqueKeysWithValues: sessions.map { summary in
        (
          summary.sessionId,
          makeTimelineEntries(
            sessionID: summary.sessionId,
            agentID: "worker-\(summary.sessionId)",
            summary: "Timeline \(summary.sessionId)"
          )
        )
      }
    )
    let client = HarnessMonitorStoreSelectionTestSupport.configuredClient(
      summaries: sessions,
      detailsByID: details,
      timelinesBySessionID: timelines,
      detail: details[sessions[0].sessionId]!
    )
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client),
      modelContainer: try HarnessMonitorModelContainer.preview()
    )
    await store.cacheSessionList(
      sessions,
      projects: [makeProject(totalSessionCount: sessions.count, activeSessionCount: sessions.count)]
    )
    store.connectionState = .online
    store.activeTransport = .webSocket

    store.schedulePersistedSnapshotHydration(using: client, sessions: sessions)

    let deadline = Date().addingTimeInterval(3)
    while totalReadCalls(client, sessions, { .sessionDetail($0) }) < sessions.count
      && Date() < deadline
    {
      try? await Task.sleep(for: .milliseconds(10))
    }

    XCTAssertEqual(totalReadCalls(client, sessions, { .sessionDetail($0) }), sessions.count)
    XCTAssertEqual(totalReadCalls(client, sessions, { .timelineWindow($0) }), sessions.count)
  }

  private func totalReadCalls(
    _ client: RecordingHarnessClient,
    _ sessions: [SessionSummary],
    _ call: (String) -> RecordingHarnessClient.ReadCall
  ) -> Int {
    sessions.reduce(0) { total, summary in
      total + client.readCallCount(call(summary.sessionId))
    }
  }
}
