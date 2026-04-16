import Testing

@testable import HarnessMonitorKit

@MainActor
extension HarnessMonitorStoreSelectionFlowTests {
  @Test("Selecting a session finishes before slow secondary panes hydrate")
  func selectingSessionFinishesBeforeSlowSecondaryPanesHydrate() async throws {
    let summary = makeSession(
      .init(
        sessionId: "sess-secondary-hydration",
        context: "Secondary hydration lane",
        status: .active,
        leaderId: "leader-secondary",
        observeId: "observe-secondary",
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 2
      )
    )
    let detail = makeSessionDetail(
      summary: summary,
      workerID: "worker-secondary",
      workerName: "Worker Secondary"
    )
    let timeline = makeTimelineEntries(
      sessionID: summary.sessionId,
      agentID: "worker-secondary",
      summary: "Primary cockpit timeline"
    )
    let run = RecordingHarnessClient().codexRunFixture(
      runID: "codex-run-secondary",
      sessionID: summary.sessionId,
      mode: .workspaceWrite,
      status: .running,
      prompt: "Inspect the lane"
    )
    let tui = RecordingHarnessClient().agentTuiFixture(
      tuiID: "agent-tui-secondary",
      sessionID: summary.sessionId,
      runtime: AgentTuiRuntime.codex.rawValue,
      status: .running,
      screenText: "codex> ready"
    )
    let client = HarnessMonitorStoreSelectionTestSupport.configuredClient(
      summaries: [summary],
      detailsByID: [summary.sessionId: detail],
      timelinesBySessionID: [summary.sessionId: timeline],
      detail: detail
    )
    client.configureDetailDelay(.milliseconds(20), for: summary.sessionId)
    client.configureTimelineDelay(.milliseconds(20), for: summary.sessionId)
    client.configureCodexRuns([run], for: summary.sessionId)
    client.configureCodexRunsDelay(.milliseconds(250), for: summary.sessionId)
    client.configureAgentTuis([tui], for: summary.sessionId)
    client.configureAgentTuisDelay(.milliseconds(250), for: summary.sessionId)
    let store = await makeBootstrappedStore(client: client)
    let completionProbe = SessionLoadCompletionProbe()

    let selectionTask = Task { @MainActor in
      await store.selectSession(summary.sessionId)
      await completionProbe.markCompleted()
    }

    try await Task.sleep(for: .milliseconds(80))

    #expect(store.selectedSession?.session.sessionId == summary.sessionId)
    #expect(store.timeline == timeline)
    #expect(store.isSelectionLoading == false)
    #expect(await completionProbe.isCompleted())
    #expect(store.selectedCodexRuns.isEmpty)
    #expect(store.selectedAgentTuis.isEmpty)

    try await Task.sleep(for: .milliseconds(320))

    #expect(store.selectedCodexRuns.map(\.runId) == [run.runId])
    #expect(store.selectedAgentTuis.map(\.tuiId) == [tui.tuiId])

    await selectionTask.value
  }

  @Test("Selecting a new session replaces subscribed session IDs")
  func selectingNewSessionReplacesSubscribedSessionIDs() async {
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
    let client = HarnessMonitorStoreSelectionTestSupport.configuredClient(
      summaries: [firstSummary, secondSummary],
      detailsByID: [
        firstSummary.sessionId: makeSessionDetail(
          summary: firstSummary,
          workerID: "worker-a",
          workerName: "Worker A"
        ),
        secondSummary.sessionId: makeSessionDetail(
          summary: secondSummary,
          workerID: "worker-b",
          workerName: "Worker B"
        ),
      ],
      detail: makeSessionDetail(
        summary: firstSummary,
        workerID: "worker-a",
        workerName: "Worker A"
      )
    )
    let store = await makeBootstrappedStore(client: client)

    await store.selectSession(firstSummary.sessionId)
    #expect(store.subscribedSessionIDs == Set([firstSummary.sessionId]))

    await store.selectSession(secondSummary.sessionId)
    #expect(store.subscribedSessionIDs == Set([secondSummary.sessionId]))
  }
}

private actor SessionLoadCompletionProbe {
  private var completed = false

  func markCompleted() {
    completed = true
  }

  func isCompleted() -> Bool {
    completed
  }
}
