import Foundation

private actor PreviewHarnessClientState {
  fileprivate static let mutationTimestamp = "2026-03-28T14:20:30Z"

  private var sessionSummaries: [SessionSummary]
  private var detailsBySessionID: [String: SessionDetail]
  private var coreDetailsBySessionID: [String: SessionDetail]
  private var timelinesBySessionID: [String: [TimelineEntry]]
  private var agentTuisBySessionID: [String: [AgentTuiSnapshot]]
  private var codexRunsBySessionID: [String: [CodexRunSnapshot]]
  private var nextAgentTuiSequence: Int
  private var nextCodexRunSequence: Int
  private let fallbackDetail: SessionDetail?
  private let fallbackTimeline: [TimelineEntry]

  init(fixtures: PreviewHarnessClient.Fixtures) {
    self.sessionSummaries = fixtures.sessions
    self.detailsBySessionID = fixtures.detailsBySessionID
    self.coreDetailsBySessionID = fixtures.coreDetailsBySessionID
    self.timelinesBySessionID = fixtures.timelinesBySessionID
    self.agentTuisBySessionID = fixtures.agentTuisBySessionID
    self.codexRunsBySessionID = fixtures.codexRunsBySessionID
    self.nextAgentTuiSequence = max(
      fixtures.agentTuisBySessionID.values.flatMap(\.self).count,
      0
    )
    self.nextCodexRunSequence = max(
      fixtures.codexRunsBySessionID.values.flatMap(\.self).count,
      0
    )
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
      let updatedText: String =
        switch request.input {
        case .text(let text), .paste(let text):
          [snapshot.screen.text, text].filter { !$0.isEmpty }.joined(separator: "\n")
        case .key(let key):
          [snapshot.screen.text, "[\(key.title)]"].filter { !$0.isEmpty }.joined(separator: "\n")
        case .control(let key):
          [snapshot.screen.text, "[Ctrl-\(String(key).uppercased())]"]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        case .rawBytesBase64:
          [snapshot.screen.text, "[raw bytes]"].filter { !$0.isEmpty }.joined(separator: "\n")
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

extension WorkItem {
  fileprivate func replacingAssignment(
    status: TaskStatus,
    assignedTo: String,
    queuePolicy: TaskQueuePolicy,
    queuedAt: String?,
    updatedAt: String
  ) -> WorkItem {
    WorkItem(
      taskId: taskId,
      title: title,
      context: context,
      severity: severity,
      status: status,
      assignedTo: assignedTo,
      queuePolicy: queuePolicy,
      queuedAt: queuedAt,
      createdAt: createdAt,
      updatedAt: updatedAt,
      createdBy: createdBy,
      notes: notes,
      suggestedFix: suggestedFix,
      source: source,
      blockedReason: nil,
      completedAt: completedAt,
      checkpointSummary: checkpointSummary
    )
  }
}

extension AgentTuiSnapshot {
  fileprivate func replacing(
    size: AgentTuiSize? = nil,
    screen: AgentTuiScreenSnapshot? = nil,
    status: AgentTuiStatus? = nil,
    exitCode: UInt32? = nil,
    signal: String? = nil
  ) -> AgentTuiSnapshot {
    AgentTuiSnapshot(
      tuiId: tuiId,
      sessionId: sessionId,
      agentId: agentId,
      runtime: runtime,
      status: status ?? self.status,
      argv: argv,
      projectDir: projectDir,
      size: size ?? self.size,
      screen: screen ?? self.screen,
      transcriptPath: transcriptPath,
      exitCode: exitCode ?? self.exitCode,
      signal: signal ?? self.signal,
      error: error,
      createdAt: createdAt,
      updatedAt: PreviewHarnessClientState.mutationTimestamp
    )
  }
}

extension AgentTuiScreenSnapshot {
  fileprivate func replacing(
    rows: Int,
    cols: Int,
    text: String
  ) -> AgentTuiScreenSnapshot {
    let lastLineLength =
      text
      .split(separator: "\n", omittingEmptySubsequences: false)
      .last?
      .count ?? 0

    return AgentTuiScreenSnapshot(
      rows: rows,
      cols: cols,
      cursorRow: max(text.split(separator: "\n", omittingEmptySubsequences: false).count, 1),
      cursorCol: min(max(lastLineLength + 1, 1), cols),
      text: text
    )
  }
}

extension SessionSummary {
  fileprivate func replacing(tasks: [WorkItem], agents: [AgentRegistration]) -> SessionSummary {
    SessionSummary(
      projectId: projectId,
      projectName: projectName,
      projectDir: projectDir,
      contextRoot: contextRoot,
      checkoutId: checkoutId,
      checkoutRoot: checkoutRoot,
      isWorktree: isWorktree,
      worktreeName: worktreeName,
      sessionId: sessionId,
      title: title,
      context: context,
      status: status,
      createdAt: createdAt,
      updatedAt: PreviewHarnessClientState.mutationTimestamp,
      lastActivityAt: PreviewHarnessClientState.mutationTimestamp,
      leaderId: leaderId,
      observeId: observeId,
      pendingLeaderTransfer: pendingLeaderTransfer,
      metrics: SessionMetrics(tasks: tasks, agents: agents)
    )
  }
}

extension SessionMetrics {
  fileprivate init(tasks: [WorkItem], agents: [AgentRegistration]) {
    self.init(
      agentCount: agents.count,
      activeAgentCount: agents.filter { $0.status == .active }.count,
      openTaskCount: tasks.filter { $0.status == .open }.count,
      inProgressTaskCount: tasks.filter { $0.status == .inProgress }.count,
      blockedTaskCount: tasks.filter { $0.status == .blocked }.count,
      completedTaskCount: tasks.filter { $0.status == .done }.count
    )
  }
}
