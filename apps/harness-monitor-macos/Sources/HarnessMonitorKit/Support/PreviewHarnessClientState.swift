import Foundation

actor PreviewHarnessClientState {
  static let mutationTimestamp = "2026-03-28T14:20:30Z"
  static let agentTuiRefreshStatusEnvironmentKey =
    "HARNESS_MONITOR_PREVIEW_AGENT_TUI_REFRESH_STATUS"

  let environment: HarnessMonitorEnvironment
  private var sessionSummaries: [SessionSummary]
  private var detailsBySessionID: [String: SessionDetail]
  private var coreDetailsBySessionID: [String: SessionDetail]
  private var timelinesBySessionID: [String: [TimelineEntry]]
  var agentTuisBySessionID: [String: [AgentTuiSnapshot]]
  var acpAgentsBySessionID: [String: [AcpAgentSnapshot]]
  var codexRunsBySessionID: [String: [CodexRunSnapshot]]
  var nextAgentTuiSequence: Int
  var nextCodexRunSequence: Int
  var nextAcpAgentSequence: Int
  private var nextMutationSecond: Int
  let fallbackDetail: SessionDetail?
  private let fallbackTimeline: [TimelineEntry]

  init(
    fixtures: PreviewHarnessClient.Fixtures,
    environment: HarnessMonitorEnvironment = .current
  ) {
    self.environment = environment
    self.sessionSummaries = fixtures.sessions
    self.detailsBySessionID = fixtures.detailsBySessionID
    self.coreDetailsBySessionID = fixtures.coreDetailsBySessionID
    self.timelinesBySessionID = fixtures.timelinesBySessionID
    self.agentTuisBySessionID = Self.seededAgentTuisBySessionID(
      fixtures: fixtures,
      environment: environment
    )
    self.acpAgentsBySessionID = Self.seededAcpAgentsBySessionID(
      fixtures: fixtures,
      environment: environment
    )
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
    self.nextMutationSecond = 30
    self.fallbackDetail = fixtures.detail
    self.fallbackTimeline = fixtures.timeline
  }

  func sessions() -> [SessionSummary] {
    sessionSummaries
  }

  func projects(templateProjects: [ProjectSummary]) -> [ProjectSummary] {
    let sessionsByProject = Dictionary(grouping: sessionSummaries, by: \.projectId)
    let activeSessionCount: (SessionSummary) -> Int = { $0.status == .ended ? 0 : 1 }

    return templateProjects.compactMap { project -> ProjectSummary? in
      let projectSessions = sessionsByProject[project.projectId] ?? []
      guard !projectSessions.isEmpty else {
        return nil
      }

      let sessionsByCheckout = Dictionary(grouping: projectSessions, by: \.checkoutId)
      let worktrees = project.worktrees.compactMap { worktree -> WorktreeSummary? in
        let checkoutSessions = sessionsByCheckout[worktree.checkoutId] ?? []
        guard !checkoutSessions.isEmpty else {
          return nil
        }

        return WorktreeSummary(
          checkoutId: worktree.checkoutId,
          name: worktree.name,
          checkoutRoot: worktree.checkoutRoot,
          contextRoot: worktree.contextRoot,
          activeSessionCount: checkoutSessions.reduce(into: 0) { partialResult, session in
            partialResult += activeSessionCount(session)
          },
          totalSessionCount: checkoutSessions.count
        )
      }

      return ProjectSummary(
        projectId: project.projectId,
        name: project.name,
        projectDir: project.projectDir,
        contextRoot: project.contextRoot,
        activeSessionCount: projectSessions.reduce(into: 0) { partialResult, session in
          partialResult += activeSessionCount(session)
        },
        totalSessionCount: projectSessions.count,
        worktrees: worktrees
      )
    }
  }

  func detail(for sessionID: String, scope: String?) -> SessionDetail? {
    if scope == "core", let coreDetail = coreDetailsBySessionID[sessionID] {
      return coreDetail
    }

    if let scopedDetail = detailsBySessionID[sessionID] {
      return scopedDetail
    }

    guard fallbackDetail?.session.sessionId == sessionID else {
      return nil
    }
    return fallbackDetail
  }

  func containsSession(_ sessionID: String) -> Bool {
    sessionSummaries.contains(where: { $0.sessionId == sessionID })
      || detailsBySessionID[sessionID] != nil
      || coreDetailsBySessionID[sessionID] != nil
      || timelinesBySessionID[sessionID] != nil
      || agentTuisBySessionID[sessionID] != nil
      || acpAgentsBySessionID[sessionID] != nil
      || codexRunsBySessionID[sessionID] != nil
      || fallbackDetail?.session.sessionId == sessionID
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
    if let timeline = timelinesBySessionID[sessionID] {
      return timeline
    }
    guard fallbackDetail?.session.sessionId == sessionID else {
      return []
    }
    return fallbackTimeline
  }

  @discardableResult
  func replaceTimeline(
    sessionID: String,
    entries: [TimelineEntry]
  ) -> SessionSummary? {
    timelinesBySessionID[sessionID] = entries
    let updatedAt = nextSyntheticMutationTimestamp()

    if let detail = currentMutableSessionDetail(sessionID: sessionID) {
      let updatedSummary = summaryByUpdatingActivity(detail.session, updatedAt: updatedAt)
      storeMutatedSessionDetail(
        SessionDetail(
          session: updatedSummary,
          agents: detail.agents,
          tasks: detail.tasks,
          signals: detail.signals,
          observer: detail.observer,
          agentActivity: detail.agentActivity
        )
      )
      return updatedSummary
    }

    guard let index = sessionSummaries.firstIndex(where: { $0.sessionId == sessionID }) else {
      return nil
    }
    let updatedSummary = summaryByUpdatingActivity(sessionSummaries[index], updatedAt: updatedAt)
    sessionSummaries[index] = updatedSummary
    return updatedSummary
  }

  private func nextSyntheticMutationTimestamp() -> String {
    nextMutationSecond = (nextMutationSecond + 1) % 60
    return String(format: "2026-03-28T14:20:%02dZ", nextMutationSecond)
  }

  private func summaryByUpdatingActivity(
    _ summary: SessionSummary,
    updatedAt: String
  ) -> SessionSummary {
    SessionSummary(
      projectId: summary.projectId,
      projectName: summary.projectName,
      projectDir: summary.projectDir,
      contextRoot: summary.contextRoot,
      sessionId: summary.sessionId,
      worktreePath: summary.worktreePath,
      sharedPath: summary.sharedPath,
      originPath: summary.originPath,
      branchRef: summary.branchRef,
      title: summary.title,
      context: summary.context,
      status: summary.status,
      createdAt: summary.createdAt,
      updatedAt: updatedAt,
      lastActivityAt: updatedAt,
      leaderId: summary.leaderId,
      observeId: summary.observeId,
      pendingLeaderTransfer: summary.pendingLeaderTransfer,
      externalOrigin: summary.externalOrigin,
      adoptedAt: summary.adoptedAt,
      metrics: summary.metrics
    )
  }

  func acpTranscript(sessionID: String) -> AcpTranscriptResponse {
    let sessionAgentIDs = Set((acpAgentsBySessionID[sessionID] ?? []).map(\.sessionAgentID))
    let entries = timeline(for: sessionID).filter {
      $0.matchesDerivedAcpTranscriptHistory(sessionAgentIDs: sessionAgentIDs)
    }
    let response = AcpTranscriptResponse(entries: entries)
    return response
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
}
