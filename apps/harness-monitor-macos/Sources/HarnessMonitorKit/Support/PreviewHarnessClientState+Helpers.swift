import Foundation

extension WorkItem {
  func replacingAssignment(
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
  func replacing(
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
  func replacing(
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
  func replacing(tasks: [WorkItem], agents: [AgentRegistration]) -> SessionSummary {
    SessionSummary(
      projectId: projectId,
      projectName: projectName,
      projectDir: projectDir,
      contextRoot: contextRoot,
      sessionId: sessionId,
      worktreePath: worktreePath,
      sharedPath: sharedPath,
      originPath: originPath,
      branchRef: branchRef,
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
  init(tasks: [WorkItem], agents: [AgentRegistration]) {
    self.init(
      agentCount: agents.count,
      activeAgentCount: agents.filter { $0.status == .active }.count,
      idleAgentCount: agents.filter { $0.status == .idle }.count,
      awaitingReviewAgentCount: agents.filter { $0.status == .awaitingReview }.count,
      openTaskCount: tasks.filter { $0.status == .open }.count,
      inProgressTaskCount: tasks.filter { $0.status == .inProgress }.count,
      awaitingReviewTaskCount: tasks.filter { $0.status == .awaitingReview }.count,
      inReviewTaskCount: tasks.filter { $0.status == .inReview }.count,
      arbitrationTaskCount: tasks.filter { $0.arbitration != nil }.count,
      blockedTaskCount: tasks.filter { $0.status == .blocked }.count,
      completedTaskCount: tasks.filter { $0.status == .done }.count
    )
  }
}
