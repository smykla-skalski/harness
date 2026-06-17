import Foundation

// Maps the generated codex wire types in
// Models/Generated/CodexWireTypes.generated.swift to the rich app models in
// HarnessMonitorCodexModels.swift. The wire types own the snake_case decode
// (explicit CodingKeys, plain PolicyWireCoding.decoder); the app models keep
// their Identifiable conformances, computed helpers (title, isActive, id,
// managedAgentID), and Int counts.
//
// CodexRunSnapshot reaches Swift nested inside ManagedAgentSnapshot.Codex (the
// adjacently-tagged managed-agents enum), so the production decode reroute lands
// with that cluster. This mapping plus the wire-contract test exercise the types
// and the mapping ahead of that wiring. The standalone codex endpoints
// (transcript, inspect, approvals, run/steer requests) reroute alongside it.
//
// CodexTranscriptResponseWire.entries is [TimelineEntry] (the hand summaries
// model, referenced not regenerated); it becomes [TimelineEntryWire] when the
// summaries subsystem migrates, at which point this mapping gains a map step.

extension CodexRunMode {
  init(wire: CodexRunModeWire) {
    // Wire and model share identical raw values; the fallback never triggers.
    self = CodexRunMode(rawValue: wire.rawValue) ?? .report
  }
}

extension CodexRunStatus {
  init(wire: CodexRunStatusWire) {
    self = CodexRunStatus(rawValue: wire.rawValue) ?? .failed
  }
}

extension CodexApprovalDecision {
  init(wire: CodexApprovalDecisionWire) {
    self = CodexApprovalDecision(rawValue: wire.rawValue) ?? .cancel
  }
}

extension CodexRunEvent {
  init(wire: CodexRunEventWire) {
    self.init(
      eventId: wire.eventId,
      sequence: wire.sequence,
      recordedAt: wire.recordedAt,
      kind: wire.kind,
      summary: wire.summary,
      threadId: wire.threadId,
      turnId: wire.turnId,
      itemId: wire.itemId,
      payload: wire.payload
    )
  }
}

extension CodexApprovalRequest {
  init(wire: CodexApprovalRequestWire) {
    self.init(
      approvalId: wire.approvalId,
      requestId: wire.requestId,
      kind: wire.kind,
      title: wire.title,
      detail: wire.detail,
      threadId: wire.threadId,
      turnId: wire.turnId,
      itemId: wire.itemId,
      cwd: wire.cwd,
      command: wire.command,
      filePath: wire.filePath
    )
  }
}

extension CodexResolvedApproval {
  init(wire: CodexResolvedApprovalWire) {
    self.init(
      approvalId: wire.approvalId,
      decision: CodexApprovalDecision(wire: wire.decision),
      resolvedAt: wire.resolvedAt
    )
  }
}

extension CodexRunSnapshot {
  init(wire: CodexRunSnapshotWire) {
    self.init(
      runId: wire.runId,
      sessionId: wire.sessionId,
      sessionAgentId: wire.sessionAgentId,
      displayName: wire.displayName,
      projectDir: wire.projectDir,
      threadId: wire.threadId,
      turnId: wire.turnId,
      mode: CodexRunMode(wire: wire.mode),
      status: CodexRunStatus(wire: wire.status),
      prompt: wire.prompt,
      latestSummary: wire.latestSummary,
      finalMessage: wire.finalMessage,
      error: wire.error,
      pendingApprovals: wire.pendingApprovals.map(CodexApprovalRequest.init(wire:)),
      resolvedApprovals: wire.resolvedApprovals.map(CodexResolvedApproval.init(wire:)),
      events: wire.events.map(CodexRunEvent.init(wire:)),
      createdAt: wire.createdAt,
      updatedAt: wire.updatedAt,
      model: wire.model,
      effort: wire.effort
    )
  }
}

extension CodexRunListResponse {
  init(wire: CodexRunListResponseWire) {
    self.init(runs: wire.runs.map(CodexRunSnapshot.init(wire:)))
  }
}

extension CodexAgentInspectSnapshot {
  init(wire: CodexAgentInspectSnapshotWire) {
    self.init(
      runId: wire.runId,
      sessionId: wire.sessionId,
      agentId: wire.agentId,
      displayName: wire.displayName,
      status: CodexRunStatus(wire: wire.status),
      projectDir: wire.projectDir,
      threadId: wire.threadId,
      turnId: wire.turnId,
      active: wire.active,
      attached: wire.attached,
      pendingApprovals: Int(wire.pendingApprovals),
      resolvedApprovals: Int(wire.resolvedApprovals),
      eventCount: Int(wire.eventCount),
      lastUpdateAt: wire.lastUpdateAt,
      model: wire.model,
      effort: wire.effort,
      latestSummary: wire.latestSummary,
      error: wire.error
    )
  }
}

extension CodexAgentInspectResponse {
  init(wire: CodexAgentInspectResponseWire) {
    self.init(
      agents: wire.agents.map(CodexAgentInspectSnapshot.init(wire:)),
      daemonPerceivedNow: wire.daemonPerceivedNow,
      available: wire.available,
      issueMessage: wire.issueMessage
    )
  }
}

extension CodexTranscriptResponse {
  init(wire: CodexTranscriptResponseWire) {
    self.init(entries: wire.entries)
  }
}

extension CodexApprovalRequestedPayload {
  init(wire: CodexApprovalRequestedPayloadWire) {
    self.init(
      run: CodexRunSnapshot(wire: wire.run),
      approval: CodexApprovalRequest(wire: wire.approval)
    )
  }
}

extension CodexRunRequestWire {
  init(_ request: CodexRunRequest) {
    // The hand request leaves role/capabilities optional; the daemon defaults them.
    self.init(
      actor: request.actor,
      prompt: request.prompt,
      mode: CodexRunModeWire(rawValue: request.mode.rawValue) ?? .report,
      role: request.role ?? .worker,
      fallbackRole: request.fallbackRole,
      capabilities: request.capabilities ?? [],
      name: request.name,
      persona: request.persona,
      resumeThreadId: request.resumeThreadId,
      taskId: request.taskID,
      boardItemId: request.boardItemID,
      workflowExecutionId: request.workflowExecutionID,
      model: request.model,
      effort: request.effort,
      allowCustomModel: request.allowCustomModel
    )
  }
}

extension CodexSteerRequestWire {
  init(_ request: CodexSteerRequest) {
    self.init(prompt: request.prompt)
  }
}

extension CodexApprovalDecisionRequestWire {
  init(_ request: CodexApprovalDecisionRequest) {
    self.init(decision: CodexApprovalDecisionWire(rawValue: request.decision.rawValue) ?? .cancel)
  }
}
