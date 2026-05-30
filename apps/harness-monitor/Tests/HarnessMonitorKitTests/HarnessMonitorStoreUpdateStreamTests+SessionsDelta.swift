import Testing

@testable import HarnessMonitorKit

extension HarnessMonitorStoreUpdateStreamTests {
  @Test("Sessions delta merges changed summaries and drops removed sessions")
  func sessionsUpdatedDeltaMergesChangedAndRemoved() async {
    let client = RecordingHarnessClient()
    let keep = makeSession(
      .init(
        sessionId: "sess-keep",
        context: "Keep cockpit",
        status: .active,
        leaderId: "leader-keep",
        observeId: nil,
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      ))
    let drop = makeSession(
      .init(
        sessionId: "sess-drop",
        context: "Drop lane",
        status: .active,
        leaderId: "leader-drop",
        observeId: nil,
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 0
      ))
    let updatedKeep = makeUpdatedSession(
      keep,
      context: "Keep cockpit updated by delta",
      updatedAt: "2026-03-31T12:05:00Z",
      agentCount: 2
    )
    let added = makeSession(
      .init(
        sessionId: "sess-added",
        context: "Added by delta",
        status: .active,
        leaderId: "leader-added",
        observeId: nil,
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      ))

    client.configureSessions(
      summaries: [keep, drop],
      detailsByID: [
        keep.sessionId: makeSessionDetail(
          summary: keep,
          workerID: "worker-keep",
          workerName: "Worker Keep"
        ),
        drop.sessionId: makeSessionDetail(
          summary: drop,
          workerID: "worker-drop",
          workerName: "Worker Drop"
        ),
      ]
    )

    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client)
    )

    await store.bootstrap()
    #expect(store.sessions.count == 2)
    let baselineSessionCalls = client.readCallCount(.sessions)

    store.applyGlobalPushEvent(
      .sessionsUpdatedDelta(
        recordedAt: "2026-03-31T12:05:00Z",
        sessionId: keep.sessionId,
        changed: [updatedKeep, added],
        removed: [drop.sessionId],
        projects: [makeProject(totalSessionCount: 2, activeSessionCount: 2)]
      )
    )

    try? await Task.sleep(for: .milliseconds(80))

    let mergedKeep = store.sessions.first { $0.sessionId == keep.sessionId }
    #expect(store.sessions.contains { $0.sessionId == drop.sessionId } == false)
    #expect(mergedKeep?.context == "Keep cockpit updated by delta")
    #expect(store.sessions.contains { $0.sessionId == added.sessionId })
    #expect(store.sessions.count == 2)
    #expect(client.readCallCount(.sessions) == baselineSessionCalls)

    store.stopAllStreams()
  }
}
