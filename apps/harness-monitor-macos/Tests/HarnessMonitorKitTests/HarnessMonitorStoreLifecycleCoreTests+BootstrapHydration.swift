import Foundation
import SwiftData
import Testing

@testable import HarnessMonitorKit

@MainActor
extension HarnessMonitorStoreLifecycleCoreTests {
  @Test("Refresh skips selected session during persisted snapshot hydration")
  func refreshSkipsSelectedSessionDuringPersistedSnapshotHydration() async throws {
    let fixtures = try await makeHydrationSkipFixtures()
    let client = fixtures.client
    let store = fixtures.store
    let selectedSummary = fixtures.selectedSummary
    let backgroundSummary = fixtures.backgroundSummary
    let selectedTimeline = fixtures.selectedTimeline
    let backgroundTimeline = fixtures.backgroundTimeline

    let updatedSelectedSummary = makeUpdatedSession(
      selectedSummary,
      context: "Selected hydration updated",
      updatedAt: "2026-03-28T15:10:00Z",
      agentCount: 2
    )
    let updatedBackgroundSummary = makeUpdatedSession(
      backgroundSummary,
      context: "Background hydration updated",
      updatedAt: "2026-03-28T15:11:00Z",
      agentCount: 2
    )
    let updatedSelectedDetail = makeSessionDetail(
      summary: updatedSelectedSummary,
      workerID: "worker-selected-hydration",
      workerName: "Worker Selected Hydration"
    )
    let updatedBackgroundDetail = makeSessionDetail(
      summary: updatedBackgroundSummary,
      workerID: "worker-background-hydration",
      workerName: "Worker Background Hydration"
    )

    client.configureSessions(
      summaries: [updatedSelectedSummary, updatedBackgroundSummary],
      detailsByID: [
        updatedSelectedSummary.sessionId: updatedSelectedDetail,
        updatedBackgroundSummary.sessionId: updatedBackgroundDetail,
      ],
      timelinesBySessionID: [
        updatedSelectedSummary.sessionId: selectedTimeline,
        updatedBackgroundSummary.sessionId: backgroundTimeline,
      ]
    )
    client.configureDetailDelay(.milliseconds(200), for: selectedSummary.sessionId)

    let baselineSelectedDetailCount = client.readCallCount(
      .sessionDetail(selectedSummary.sessionId))
    let baselineSelectedTimelineCount = client.readCallCount(
      .timelineWindow(selectedSummary.sessionId))
    let baselineBackgroundDetailCount = client.readCallCount(
      .sessionDetail(backgroundSummary.sessionId))
    let baselineBackgroundTimelineCount = client.readCallCount(
      .timelineWindow(backgroundSummary.sessionId))

    await store.refresh(using: client, preserveSelection: true)
    try? await Task.sleep(for: .milliseconds(40))

    #expect(
      client.readCallCount(.sessionDetail(backgroundSummary.sessionId))
        == baselineBackgroundDetailCount)
    #expect(
      client.readCallCount(.timelineWindow(backgroundSummary.sessionId))
        == baselineBackgroundTimelineCount)

    for _ in 0..<50 {
      let selectedTimelineCount = client.readCallCount(
        .timelineWindow(selectedSummary.sessionId))
      let backgroundTimelineCount = client.readCallCount(
        .timelineWindow(backgroundSummary.sessionId))
      if selectedTimelineCount > baselineSelectedTimelineCount
        && backgroundTimelineCount > baselineBackgroundTimelineCount
      {
        break
      }
      try? await Task.sleep(for: .milliseconds(10))
    }

    #expect(
      client.readCallCount(.sessionDetail(selectedSummary.sessionId)) == baselineSelectedDetailCount
        + 1)
    #expect(
      client.readCallCount(.timelineWindow(selectedSummary.sessionId))
        == baselineSelectedTimelineCount + 1)
    #expect(
      client.readCallCount(.sessionDetail(backgroundSummary.sessionId))
        == baselineBackgroundDetailCount + 1)
    #expect(
      client.readCallCount(.timelineWindow(backgroundSummary.sessionId))
        == baselineBackgroundTimelineCount + 1)
    #expect(client.sessionDetailScopes(for: selectedSummary.sessionId).last == "core")
    #expect(client.sessionDetailScopes(for: backgroundSummary.sessionId).last == "core")
  }

  @Test("Refresh prefers summary timeline scope during HTTP persisted snapshot hydration")
  func refreshPrefersSummaryTimelineScopeDuringHTTPPersistedSnapshotHydration() async throws {
    let fixtures = try await makeHydrationSkipFixtures()
    let client = fixtures.client
    let store = fixtures.store
    let backgroundSummary = fixtures.backgroundSummary

    store.activeTransport = .httpSSE
    let baselineBackgroundTimelineCount = client.readCallCount(
      .timelineWindow(backgroundSummary.sessionId))

    await store.refresh(using: client, preserveSelection: true)

    for _ in 0..<50 {
      let backgroundTimelineCount = client.readCallCount(
        .timelineWindow(backgroundSummary.sessionId))
      if backgroundTimelineCount > baselineBackgroundTimelineCount {
        break
      }
      try? await Task.sleep(for: .milliseconds(10))
    }

    let backgroundDetailScopes = client.sessionDetailScopes(for: backgroundSummary.sessionId)
    #expect(backgroundDetailScopes.isEmpty == false)
    #expect(backgroundDetailScopes.last! == nil)
    #expect(
      client.recordedTimelineWindowRequests(for: backgroundSummary.sessionId).last
        == .latest(limit: 10)
    )
  }

  @Test("Replacing the session snapshot clears removed selection across UI slices")
  func replacingSessionSnapshotClearsRemovedSelectionAcrossUISlices() async {
    let selectedSummary = makeSession(
      .init(
        sessionId: "sess-selected",
        context: "Selected cockpit",
        status: .active,
        leaderId: "leader-selected",
        observeId: "observe-selected",
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      )
    )
    let selectedDetail = makeSessionDetail(
      summary: selectedSummary,
      workerID: "worker-selected",
      workerName: "Worker Selected"
    )
    let selectedTimeline = makeTimelineEntries(
      sessionID: selectedSummary.sessionId,
      agentID: "worker-selected",
      summary: "Selected timeline"
    )
    let client = HarnessMonitorStoreSelectionTestSupport.configuredClient(
      summaries: [selectedSummary],
      detailsByID: [selectedSummary.sessionId: selectedDetail],
      timelinesBySessionID: [selectedSummary.sessionId: selectedTimeline],
      detail: selectedDetail
    )
    let store = await makeBootstrappedStore(client: client)

    await store.selectSession(selectedSummary.sessionId)
    #expect(store.sidebarUI.selectedSessionID == selectedSummary.sessionId)
    #expect(store.contentUI.session.selectedSessionSummary == selectedSummary)

    let replacementSummary = makeSession(
      .init(
        sessionId: "sess-replacement",
        context: "Replacement cockpit",
        status: .active,
        leaderId: "leader-replacement",
        observeId: "observe-replacement",
        openTaskCount: 0,
        inProgressTaskCount: 1,
        blockedTaskCount: 0,
        activeAgentCount: 1,
        lastActivityAt: "2026-03-28T14:19:00Z"
      )
    )

    store.applySessionIndexSnapshot(
      projects: [makeProject(totalSessionCount: 1, activeSessionCount: 1)],
      sessions: [replacementSummary]
    )

    #expect(store.selectedSessionID == nil)
    #expect(store.selectedSession == nil)
    #expect(store.timeline.isEmpty)
    #expect(store.subscribedSessionIDs.isEmpty)
    #expect(store.sidebarUI.selectedSessionID == nil)
    #expect(store.contentUI.session.selectedSessionSummary == nil)
  }

  @Test("Bootstrap snapshot retry loop exits promptly when the bootstrap task is cancelled")
  func bootstrapRetryLoopStopsWhenCancelled() async {
    let client = RecordingHarnessClient()
    let persistentErrors: [any Error] = (0..<256).map { _ in
      HarnessMonitorAPIError.server(code: 503, message: "daemon snapshot warming up")
    }
    client.configureDiagnosticsErrors(persistentErrors)
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client)
    )
    store.initialConnectRefreshRetryGracePeriod = .seconds(5)
    store.initialConnectRefreshRetryInterval = .seconds(1)

    let bootstrapTask = Task { @MainActor in
      await store.bootstrap()
    }

    try? await Task.sleep(for: .milliseconds(20))
    bootstrapTask.cancel()

    #expect(await taskCompletes(bootstrapTask, timeout: .milliseconds(200)))
  }
}

private func taskCompletes(
  _ task: Task<Void, Never>,
  timeout: Duration
) async -> Bool {
  await withTaskGroup(of: Bool.self) { group in
    group.addTask {
      await task.value
      return true
    }
    group.addTask {
      try? await Task.sleep(for: timeout)
      return false
    }

    let completed = await group.next() ?? false
    group.cancelAll()
    return completed
  }
}
