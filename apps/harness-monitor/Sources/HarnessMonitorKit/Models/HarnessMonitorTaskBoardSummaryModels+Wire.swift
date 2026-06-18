import Foundation

// Map the generated task-board summary wire types to the thin hand models. The
// wire types own the daemon snake_case decode through the plain decoder; the hand
// models keep their Int counts and the adopted TaskBoardStatus/TaskBoardAgentMode
// enums pass straight through. The sync summary now generates too - its external
// provider/action enums ride bare and the changed/unsupported field lists are dropped.

extension TaskBoardStatusCount {
  public init(wire: TaskBoardStatusCountWire) {
    self.init(status: wire.status, count: Int(wire.count))
  }
}

extension TaskBoardAuditSummary {
  public init(wire: TaskBoardAuditSummaryWire) {
    self.init(
      total: Int(wire.total),
      ready: Int(wire.ready),
      blocked: Int(wire.blocked),
      deleted: Int(wire.deleted),
      byStatus: wire.byStatus.map(TaskBoardStatusCount.init(wire:))
    )
  }
}

extension TaskBoardProjectSummary {
  public init(wire: TaskBoardProjectSummaryWire) {
    self.init(
      projectId: wire.projectId,
      itemCount: Int(wire.itemCount),
      readyCount: Int(wire.readyCount)
    )
  }
}

extension TaskBoardMachineSummary {
  public init(wire: TaskBoardMachineSummaryWire) {
    self.init(
      mode: wire.mode,
      itemCount: Int(wire.itemCount),
      readyCount: Int(wire.readyCount)
    )
  }
}

extension TaskBoardProviderSyncSummary {
  init(wire: TaskBoardProviderSyncSummaryWire) {
    self.init(
      provider: wire.provider,
      configured: wire.configured,
      linked: Int(wire.linked),
      pushable: Int(wire.pushable),
      blocked: Int(wire.blocked),
      tokenEnv: wire.tokenEnv
    )
  }
}

extension TaskBoardExternalSyncOperation {
  init(wire: ExternalSyncOperationWire) {
    self.init(
      provider: wire.provider,
      action: wire.action,
      boardItemId: wire.boardItemId,
      externalId: wire.externalId,
      url: wire.url,
      dryRun: wire.dryRun,
      applied: wire.applied
    )
  }
}

extension TaskBoardSyncSummary {
  init(wire: TaskBoardSyncSummaryWire) {
    self.init(
      total: Int(wire.total),
      providers: wire.providers.map(TaskBoardProviderSyncSummary.init(wire:)),
      operations: wire.operations.map(TaskBoardExternalSyncOperation.init(wire:))
    )
  }
}
