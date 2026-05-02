import Foundation

actor PreviewHarnessClientState {
  static let mutationTimestamp = "2026-03-28T14:20:30Z"
  static let agentTuiRefreshStatusEnvironmentKey =
    "HARNESS_MONITOR_PREVIEW_AGENT_TUI_REFRESH_STATUS"

  private var sessionSummaries: [SessionSummary]
  private var detailsBySessionID: [String: SessionDetail]
  private var coreDetailsBySessionID: [String: SessionDetail]
  private var timelinesBySessionID: [String: [TimelineEntry]]
  var agentTuisBySessionID: [String: [AgentTuiSnapshot]]
  var acpAgentsBySessionID: [String: [AcpAgentSnapshot]]
  var codexRunsBySessionID: [String: [CodexRunSnapshot]]
  private var nextAgentTuiSequence: Int
  private var nextCodexRunSequence: Int
  var nextAcpAgentSequence: Int
  let fallbackDetail: SessionDetail?
  private let fallbackTimeline: [TimelineEntry]

  init(fixtures: PreviewHarnessClient.Fixtures) {
    self.sessionSummaries = fixtures.sessions
    self.detailsBySessionID = fixtures.detailsBySessionID
    self.coreDetailsBySessionID = fixtures.coreDetailsBySessionID
    self.timelinesBySessionID = fixtures.timelinesBySessionID
    self.agentTuisBySessionID = Self.seededAgentTuisBySessionID(fixtures: fixtures)
    self.acpAgentsBySessionID = Self.seededAcpAgentsBySessionID(fixtures: fixtures)
    self.codexRunsBySessionID = fixtures.codexRunsBySessionID
    self.nextAgentTuiSequence = max(
      fixtures.agentTuisBySessionID.values.flatMap(\.self).count,
      0
    )
    self.nextCodexRunSequence = max(
      fixtures.codexRunsBySessionID.values.flatMap(\.self).count,
      0
    )
    self.nextAcpAgentSequence = 0
    self.fallbackDetail = fixtures.detail
    self.fallbackTimeline = fixtures.timeline
  }

  func sessions() -> [SessionSummary] {
    sessionSummaries
  }

  func detail(for sessionID: String, scope: String?) -> SessionDetail? {
    if scope == "core", let coreDetail = coreDetailsBySessionID[sessionID] {
      return coreDetail
    }

    if let scopedDetail = detailsBySessionID[sessionID] {
      return scopedDetail
    }

    return fallbackDetail
  }

  func currentMutableSessionDetail(sessionID: String) -> SessionDetail? {
    if let detail = detailsBySessionID[sessionID] {
      return detail
    }
    if let fallbackDetail, fallbackDetail.session.sessionId == sessionID {
      return fallbackDetail
    }
    return nil
  }

  func storeMutatedSessionDetail(_ detail: SessionDetail) {
    let sessionID = detail.session.sessionId
    detailsBySessionID[sessionID] = detail
    if coreDetailsBySessionID[sessionID] != nil {
      coreDetailsBySessionID[sessionID] = detail
    }
    if let index = sessionSummaries.firstIndex(where: { $0.sessionId == sessionID }) {
      sessionSummaries[index] = detail.session
    }
  }

  func archiveSession(sessionID: String) throws -> SessionArchiveResponse {
    guard sessionSummaries.contains(where: { $0.sessionId == sessionID }) else {
      throw HarnessMonitorAPIError.server(code: 404, message: "No preview session available.")
    }

    sessionSummaries.removeAll { $0.sessionId == sessionID }
    detailsBySessionID.removeValue(forKey: sessionID)
    coreDetailsBySessionID.removeValue(forKey: sessionID)
    timelinesBySessionID.removeValue(forKey: sessionID)
    agentTuisBySessionID.removeValue(forKey: sessionID)
    acpAgentsBySessionID.removeValue(forKey: sessionID)
    codexRunsBySessionID.removeValue(forKey: sessionID)

    return SessionArchiveResponse(
      sessionId: sessionID,
      archivedAt: Self.mutationTimestamp
    )
  }

  func timeline(for sessionID: String) -> [TimelineEntry] {
    timelinesBySessionID[sessionID] ?? fallbackTimeline
  }

  func codexRuns(sessionID: String) -> [CodexRunSnapshot] {
    codexRunsBySessionID[sessionID] ?? []
  }

  func codexRun(runID: String) -> CodexRunSnapshot? {
    codexRunsBySessionID.values
      .flatMap(\.self)
      .first { run in
        run.runId == runID
      }
  }

  func startCodexRun(
    sessionID: String,
    request: CodexRunRequest
  ) -> CodexRunSnapshot {
    nextCodexRunSequence += 1
    let run = CodexRunSnapshot(
      runId: "preview-codex-run-\(nextCodexRunSequence)",
      sessionId: sessionID,
      projectDir: fallbackDetail?.session.projectDir ?? "/Users/example/Projects/harness",
      threadId: request.resumeThreadId,
      turnId: nil,
      mode: request.mode,
      status: .queued,
      prompt: request.prompt,
      latestSummary: request.actor.map { "Queued by \($0)" } ?? "Queued by preview",
      finalMessage: nil,
      error: nil,
      pendingApprovals: [],
      createdAt: Self.mutationTimestamp,
      updatedAt: Self.mutationTimestamp
    )
    var runs = codexRunsBySessionID[sessionID] ?? []
    runs.removeAll { $0.runId == run.runId }
    runs.insert(run, at: 0)
    codexRunsBySessionID[sessionID] = runs
    return run
  }

  func agentTuis(sessionID: String) -> [AgentTuiSnapshot] {
    agentTuisBySessionID[sessionID] ?? []
  }

  func agentTui(tuiID: String) -> AgentTuiSnapshot? {
    agentTuisBySessionID.values
      .flatMap(\.self)
      .first { tui in
        tui.tuiId == tuiID
      }
  }

  func startAgentTui(
    sessionID: String,
    request: AgentTuiStartRequest
  ) -> AgentTuiSnapshot {
    nextAgentTuiSequence += 1
    let runtimeTitle =
      AgentTuiRuntime(rawValue: request.runtime)?.title ?? request.runtime.capitalized
    let introText =
      if let prompt = request.prompt, !prompt.isEmpty {
        "\(runtimeTitle.lowercased())> \(prompt)"
      } else {
        "\(runtimeTitle.lowercased())> ready"
      }

    let snapshot = AgentTuiSnapshot(
      tuiId: "preview-agent-tui-\(nextAgentTuiSequence)",
      sessionId: sessionID,
      agentId: "preview-agent-\(nextAgentTuiSequence)",
      runtime: request.runtime,
      status: .running,
      argv: request.argv.isEmpty ? [request.runtime] : request.argv,
      projectDir: request.projectDir ?? fallbackDetail?.session.projectDir
        ?? "/Users/example/Projects/harness",
      size: AgentTuiSize(rows: request.rows, cols: request.cols),
      screen: AgentTuiScreenSnapshot(
        rows: request.rows,
        cols: request.cols,
        cursorRow: 1,
        cursorCol: min(max(introText.count + 1, 1), request.cols),
        text: introText
      ),
      transcriptPath:
        "/Users/example/Projects/harness/transcripts/preview-agent-tui-\(nextAgentTuiSequence).log",
      exitCode: nil,
      signal: nil,
      error: nil,
      createdAt: Self.mutationTimestamp,
      updatedAt: Self.mutationTimestamp
    )

    var sessionTuis = agentTuisBySessionID[sessionID] ?? []
    sessionTuis.insert(snapshot, at: 0)
    agentTuisBySessionID[sessionID] = sessionTuis
    return snapshot
  }

  func sendAgentTuiInput(
    tuiID: String,
    request: AgentTuiInputRequest
  ) -> AgentTuiSnapshot? {
    mutateAgentTui(tuiID: tuiID) { snapshot in
      let updatedText = request.replayedInputs.reduce(snapshot.screen.text) { screenText, input in
        switch input {
        case .text(let text), .paste(let text):
          [screenText, text].filter { !$0.isEmpty }.joined(separator: "\n")
        case .key(let key):
          [screenText, "[\(key.title)]"].filter { !$0.isEmpty }.joined(separator: "\n")
        case .control(let key):
          [screenText, "[Ctrl-\(String(key).uppercased())]"]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        case .rawBytesBase64:
          [screenText, "[raw bytes]"].filter { !$0.isEmpty }.joined(separator: "\n")
        }
      }

      return snapshot.replacing(
        screen: snapshot.screen.replacing(
          rows: snapshot.screen.rows,
          cols: snapshot.screen.cols,
          text: updatedText
        )
      )
    }
  }

  func resizeAgentTui(
    tuiID: String,
    request: AgentTuiResizeRequest
  ) -> AgentTuiSnapshot? {
    mutateAgentTui(tuiID: tuiID) { snapshot in
      snapshot.replacing(
        size: AgentTuiSize(rows: request.rows, cols: request.cols),
        screen: snapshot.screen.replacing(
          rows: request.rows,
          cols: request.cols,
          text: snapshot.screen.text
        )
      )
    }
  }

  func stopAgentTui(tuiID: String) -> AgentTuiSnapshot? {
    mutateAgentTui(tuiID: tuiID) { snapshot in
      snapshot.replacing(
        status: .stopped,
        exitCode: 0,
        signal: nil
      )
    }
  }

  func managedAgent(agentID: String) -> ManagedAgentSnapshot? {
    agentTuisBySessionID.values
      .flatMap(\.self)
      .map(ManagedAgentSnapshot.terminal)
      .first { $0.agentId == agentID }
      ?? codexRunsBySessionID.values
      .flatMap(\.self)
      .map(ManagedAgentSnapshot.codex)
      .first { $0.agentId == agentID }
      ?? acpAgentsBySessionID.values
      .flatMap(\.self)
      .map(ManagedAgentSnapshot.acp)
      .first { $0.agentId == agentID }
  }

  func dropTask(
    sessionID: String,
    taskID: String,
    request: TaskDropRequest
  ) throws -> SessionDetail {
    guard let detail = detail(for: sessionID, scope: nil) else {
      throw HarnessMonitorAPIError.server(
        code: 404,
        message: "No preview session detail available."
      )
    }

    guard let taskIndex = detail.tasks.firstIndex(where: { $0.taskId == taskID }) else {
      throw HarnessMonitorAPIError.server(code: 404, message: "No preview task available.")
    }

    let targetAgentID: String
    switch request.target {
    case .agent(let agentID):
      targetAgentID = agentID
    }

    guard let agentIndex = detail.agents.firstIndex(where: { $0.agentId == targetAgentID }) else {
      throw HarnessMonitorAPIError.server(code: 404, message: "No preview agent available.")
    }

    let agent = detail.agents[agentIndex]
    guard agent.role == .worker, agent.status == .active else {
      throw HarnessMonitorAPIError.server(code: 409, message: "Preview agent cannot take tasks.")
    }

    var tasks = detail.tasks
    let agents = detail.agents
    let task = tasks[taskIndex]
    tasks[taskIndex] = task.replacingAssignment(
      status: .open,
      assignedTo: targetAgentID,
      queuePolicy: request.queuePolicy,
      queuedAt: agent.currentTaskId == nil ? nil : Self.mutationTimestamp,
      updatedAt: Self.mutationTimestamp
    )

    let updatedDetail = SessionDetail(
      session: detail.session.replacing(tasks: tasks, agents: agents),
      agents: agents,
      tasks: tasks,
      signals: detail.signals,
      observer: detail.observer,
      agentActivity: detail.agentActivity
    )

    detailsBySessionID[sessionID] = updatedDetail
    if coreDetailsBySessionID[sessionID] != nil {
      coreDetailsBySessionID[sessionID] = updatedDetail
    }
    if let sessionIndex = sessionSummaries.firstIndex(where: { $0.sessionId == sessionID }) {
      sessionSummaries[sessionIndex] = updatedDetail.session
    }
    return updatedDetail
  }

  private func mutateAgentTui(
    tuiID: String,
    mutation: (AgentTuiSnapshot) -> AgentTuiSnapshot
  ) -> AgentTuiSnapshot? {
    for (sessionID, snapshots) in agentTuisBySessionID {
      guard let index = snapshots.firstIndex(where: { $0.tuiId == tuiID }) else {
        continue
      }

      var updatedSnapshots = snapshots
      updatedSnapshots[index] = mutation(snapshots[index])
      agentTuisBySessionID[sessionID] = updatedSnapshots
      return updatedSnapshots[index]
    }

    return nil
  }
}
