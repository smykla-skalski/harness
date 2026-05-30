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

    // The primary selection (session detail + timeline) resolves while the slow
    // codex-run and agent-TUI panes are still in their 250ms hydration delay, so
    // awaiting the selection task itself is the deterministic "selection finished"
    // point. Secondary panes must still be empty here.
    await selectionTask.value

    #expect(store.selectedSession?.session.sessionId == summary.sessionId)
    #expect(store.timeline == timeline)
    #expect(store.isSelectionLoading == false)
    #expect(await completionProbe.isCompleted())
    #expect(store.selectedCodexRuns.isEmpty)
    #expect(store.selectedAgentTuis.isEmpty)

    try await Task.sleep(for: .milliseconds(320))

    #expect(store.selectedCodexRuns.map(\.runId) == [run.runId])
    #expect(store.selectedAgentTuis.map(\.tuiId) == [tui.tuiId])
  }

  @Test("Selecting a session hydrates ACP transcript history independently")
  func selectingSessionHydratesAcpTranscriptHistoryIndependently() async throws {
    let summary = makeSession(
      .init(
        sessionId: "sess-secondary-acp-transcript",
        context: "ACP transcript hydration lane",
        status: .active,
        leaderId: "leader-acp-secondary",
        observeId: "observe-acp-secondary",
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 2
      )
    )
    let detail = makeSessionDetail(
      summary: summary,
      workerID: "worker-acp-secondary",
      workerName: "Worker ACP Secondary"
    )
    let cockpitTimeline = makeTimelineEntries(
      sessionID: summary.sessionId,
      agentID: "worker-acp-secondary",
      summary: "Cockpit timeline row"
    )
    let transcriptEntry = TimelineEntry(
      entryId: "acp-transcript-secondary",
      recordedAt: "2026-04-28T00:00:20Z",
      kind: "assistant_message",
      sessionId: summary.sessionId,
      agentId: "worker-acp-secondary",
      taskId: nil,
      summary: "Dedicated ACP transcript row",
      payload: .object(["runtime": .string("acp")])
    )
    let client = HarnessMonitorStoreSelectionTestSupport.configuredClient(
      summaries: [summary],
      detailsByID: [summary.sessionId: detail],
      timelinesBySessionID: [summary.sessionId: cockpitTimeline],
      detail: detail
    )
    client.configureAcpTranscriptResponse(
      AcpTranscriptResponse(entries: [transcriptEntry]),
      for: summary.sessionId
    )
    client.configureAcpTranscriptDelay(.milliseconds(250), for: summary.sessionId)
    let store = await makeBootstrappedStore(client: client)

    await store.selectSession(summary.sessionId)
    try await Task.sleep(for: .milliseconds(80))

    #expect(store.timeline.map(\.summary) == ["Cockpit timeline row"])
    #expect(store.acpTranscript(forAgent: "worker-acp-secondary").isEmpty)

    try await Task.sleep(for: .milliseconds(260))

    #expect(store.timeline.map(\.summary) == ["Cockpit timeline row"])
    #expect(
      store.acpTranscript(forAgent: "worker-acp-secondary").map(\.summary)
        == ["Dedicated ACP transcript row"]
    )
    #expect(client.acpTranscriptCallCount(for: summary.sessionId) == 1)
  }

  @Test("Selecting a session keeps managed native-runtime ACP transcript history")
  func selectingSessionKeepsManagedNativeRuntimeAcpTranscriptHistory() async throws {
    let summary = makeSession(
      .init(
        sessionId: "sess-secondary-acp-native-transcript",
        context: "Managed native transcript hydration lane",
        status: .active,
        leaderId: "leader-acp-native",
        observeId: "observe-acp-native",
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 2
      )
    )
    let detail = makeSessionDetail(
      summary: summary,
      workerID: "worker-acp-native",
      workerName: "Worker ACP Native"
    )
    let cockpitTimeline = makeTimelineEntries(
      sessionID: summary.sessionId,
      agentID: "worker-acp-native",
      summary: "Cockpit timeline row"
    )
    let transcriptEntry = TimelineEntry(
      entryId: "gemini-worker-acp-native-assistant_text-7",
      recordedAt: "2026-04-28T00:00:20Z",
      kind: "assistant_text",
      sessionId: summary.sessionId,
      agentId: "worker-acp-native",
      taskId: nil,
      summary: "Dedicated Gemini transcript row",
      payload: .object([
        "runtime": .string("gemini"),
        "event": .object([
          "type": .string("assistant_text"),
          "content": .string("Dedicated Gemini transcript row"),
        ]),
      ])
    )
    let client = HarnessMonitorStoreSelectionTestSupport.configuredClient(
      summaries: [summary],
      detailsByID: [summary.sessionId: detail],
      timelinesBySessionID: [summary.sessionId: cockpitTimeline],
      detail: detail
    )
    client.configureAcpTranscriptResponse(
      AcpTranscriptResponse(entries: [transcriptEntry]),
      for: summary.sessionId
    )
    client.configureAcpTranscriptDelay(.milliseconds(250), for: summary.sessionId)
    let store = await makeBootstrappedStore(client: client)

    await store.selectSession(summary.sessionId)
    try await Task.sleep(for: .milliseconds(80))

    #expect(store.timeline.map(\.summary) == ["Cockpit timeline row"])
    #expect(store.acpTranscript(forAgent: "worker-acp-native").isEmpty)

    try await Task.sleep(for: .milliseconds(260))

    #expect(store.timeline.map(\.summary) == ["Cockpit timeline row"])
    #expect(
      store.acpTranscript(forAgent: "worker-acp-native").map(\.summary)
        == ["Dedicated Gemini transcript row"]
    )
    #expect(client.acpTranscriptCallCount(for: summary.sessionId) == 1)
  }

  @Test("Recording client derives managed native ACP transcript fallback from timeline")
  func recordingClientDerivesManagedNativeAcpTranscriptFallbackFromTimeline() async throws {
    let summary = makeSession(
      .init(
        sessionId: "sess-recording-client-acp-native",
        context: "Recording client ACP transcript lane",
        status: .active,
        leaderId: "leader-recording-native",
        observeId: "observe-recording-native",
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 2
      )
    )
    let detail = makeSessionDetail(
      summary: summary,
      workerID: "worker-recording-native",
      workerName: "Worker Recording Native"
    )
    let cockpitRow = TimelineEntry(
      entryId: "cockpit-row",
      recordedAt: "2026-04-28T00:00:10Z",
      kind: "task_started",
      sessionId: summary.sessionId,
      agentId: "worker-recording-native",
      taskId: nil,
      summary: "Cockpit timeline row",
      payload: .object([:])
    )
    let transcriptRow = TimelineEntry(
      entryId: "gemini-worker-recording-native-assistant_text-8",
      recordedAt: "2026-04-28T00:00:20Z",
      kind: "assistant_text",
      sessionId: summary.sessionId,
      agentId: "worker-recording-native",
      taskId: nil,
      summary: "Managed native transcript row",
      payload: .object([
        "runtime": .string("gemini"),
        "event": .object([
          "type": .string("assistant_text"),
          "content": .string("Managed native transcript row"),
        ]),
      ])
    )
    let client = HarnessMonitorStoreSelectionTestSupport.configuredClient(
      summaries: [summary],
      detailsByID: [summary.sessionId: detail],
      timelinesBySessionID: [summary.sessionId: [cockpitRow, transcriptRow]],
      detail: detail
    )
    client.configureResolvedAcpSnapshot(
      makeAcpSnapshot(
        acpID: "acp-recording-native",
        sessionID: summary.sessionId,
        agentID: "worker-recording-native",
        displayName: "Worker Recording Native",
        pendingBatches: []
      ),
      for: "worker-recording-native"
    )

    let response = try await client.acpTranscript(sessionID: summary.sessionId)

    #expect(response.entries.map(\.summary) == ["Managed native transcript row"])
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
