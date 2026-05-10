import Testing

@testable import HarnessMonitorKit

extension HarnessMonitorStoreActionTests {
  @Test("Observe selected session tracks the last action")
  func observeSelectedSessionTracksLastAction() async {
    let client = RecordingHarnessClient()
    let store = await selectedActionStore(client: client)

    await store.observeSelectedSession(actor: "observer-gwen")

    #expect(
      client.recordedCalls()
        == [
          .observeSession(
            sessionID: PreviewFixtures.summary.sessionId,
            actor: "observer-gwen"
          )
        ]
    )
    #expect(store.currentSuccessFeedbackMessage == "Observe session")
  }

  @Test("Observe selected session refreshes summary state and triggers supervisor decisions")
  func observeSelectedSessionRefreshesSummaryStateAndTriggersSupervisorDecisions() async throws {
    let baselineDetail = PreviewFixtures.sessionDetail(
      session: PreviewFixtures.summary,
      signals: PreviewFixtures.signals,
      observer: nil,
      agentActivity: PreviewFixtures.agentActivity
    )
    let client = RecordingHarnessClient(detail: baselineDetail)
    let store = await selectedActionStore(client: client)

    let updatedSummary = observeResponseSummary(updatedAt: "2026-03-28T14:30:00Z")
    client.detail = PreviewFixtures.sessionDetail(
      session: updatedSummary,
      signals: PreviewFixtures.signals,
      observer: PreviewFixtures.observer,
      agentActivity: PreviewFixtures.agentActivity
    )

    #expect(store.supervisorOpenDecisions.isEmpty)

    await store.observeSelectedSession(actor: "observer-gwen")
    try await Task.sleep(for: .milliseconds(150))

    #expect(
      store.selectedSession?.observer?.openIssueCount == PreviewFixtures.observer.openIssueCount
    )
    #expect(
      store.sessionIndex.sessionSummary(for: PreviewFixtures.summary.sessionId)?.updatedAt
        == updatedSummary.updatedAt
    )
    #expect(store.supervisorOpenDecisions.isEmpty == false)
  }

  @Test("Mutation fallback refetches only the timeline")
  func mutationFallbackRefetchesOnlyTheTimeline() async {
    let client = RecordingHarnessClient()
    let store = await selectedActionStore(client: client)
    store.sessionPushFallbackDelay = .milliseconds(20)
    let sessionID = PreviewFixtures.summary.sessionId

    let baselineHealthCalls = client.readCallCount(.health)
    let baselineDiagnosticsCalls = client.readCallCount(.diagnostics)
    let baselineProjectsCalls = client.readCallCount(.projects)
    let baselineSessionsCalls = client.readCallCount(.sessions)
    let baselineDetailCalls = client.readCallCount(.sessionDetail(sessionID))
    let baselineTimelineCalls = client.readCallCount(.timelineWindow(sessionID))

    let created = await store.createTask(
      title: "Fallback-only task",
      context: "Verify no broad refresh happens",
      severity: .medium
    )
    #expect(created)

    try? await Task.sleep(for: .milliseconds(1_050))

    #expect(client.readCallCount(.health) == baselineHealthCalls)
    #expect(client.readCallCount(.diagnostics) == baselineDiagnosticsCalls)
    #expect(client.readCallCount(.projects) == baselineProjectsCalls)
    #expect(client.readCallCount(.sessions) == baselineSessionsCalls)
    #expect(client.readCallCount(.sessionDetail(sessionID)) == baselineDetailCalls)
    #expect(client.readCallCount(.timelineWindow(sessionID)) == baselineTimelineCalls + 1)

    store.stopAllStreams()
  }

  @Test("End selected session tracks the last action and status")
  func endSelectedSessionTracksLastActionAndStatus() async {
    let client = RecordingHarnessClient()
    let store = await selectedActionStore(client: client)

    await store.endSelectedSession(actor: "leader-claude")

    #expect(
      client.recordedCalls()
        == [
          .endSession(
            sessionID: PreviewFixtures.summary.sessionId,
            actor: "leader-claude"
          )
        ]
    )
    #expect(store.selectedSession?.session.status == .ended)
    #expect(store.currentSuccessFeedbackMessage == "End session")
  }
}
