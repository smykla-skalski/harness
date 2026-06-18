import Foundation

// Wire maps for the SessionDetail.session member (SessionSummary) plus its metrics and pending
// leader transfer. SessionMetrics narrows all eleven counts UInt32 -> Int; SessionStatus is a
// decoder-agnostic hand enum the wire references bare, so it carries through unchanged.

extension SessionMetrics {
  init(wire: SessionMetricsWire) {
    self.init(
      agentCount: Int(wire.agentCount),
      activeAgentCount: Int(wire.activeAgentCount),
      idleAgentCount: Int(wire.idleAgentCount),
      awaitingReviewAgentCount: Int(wire.awaitingReviewAgentCount),
      openTaskCount: Int(wire.openTaskCount),
      inProgressTaskCount: Int(wire.inProgressTaskCount),
      awaitingReviewTaskCount: Int(wire.awaitingReviewTaskCount),
      inReviewTaskCount: Int(wire.inReviewTaskCount),
      arbitrationTaskCount: Int(wire.arbitrationTaskCount),
      blockedTaskCount: Int(wire.blockedTaskCount),
      completedTaskCount: Int(wire.completedTaskCount)
    )
  }
}

extension PendingLeaderTransfer {
  init(wire: PendingLeaderTransferWire) {
    self.init(
      requestedBy: wire.requestedBy,
      currentLeaderId: wire.currentLeaderId,
      newLeaderId: wire.newLeaderId,
      requestedAt: wire.requestedAt,
      reason: wire.reason
    )
  }
}

extension SessionSummary {
  init(wire: SessionSummaryWire) {
    self.init(
      projectId: wire.projectId,
      projectName: wire.projectName,
      projectDir: wire.projectDir,
      contextRoot: wire.contextRoot,
      sessionId: wire.sessionId,
      worktreePath: wire.worktreePath,
      sharedPath: wire.sharedPath,
      originPath: wire.originPath,
      branchRef: wire.branchRef,
      title: wire.title,
      context: wire.context,
      status: wire.status,
      createdAt: wire.createdAt,
      updatedAt: wire.updatedAt,
      lastActivityAt: wire.lastActivityAt,
      leaderId: wire.leaderId,
      observeId: wire.observeId,
      pendingLeaderTransfer: wire.pendingLeaderTransfer.map(PendingLeaderTransfer.init(wire:)),
      externalOrigin: wire.externalOrigin,
      adoptedAt: wire.adoptedAt,
      metrics: SessionMetrics(wire: wire.metrics)
    )
  }
}
