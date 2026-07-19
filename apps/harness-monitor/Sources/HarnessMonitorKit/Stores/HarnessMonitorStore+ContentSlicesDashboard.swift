import Foundation
import Observation

extension HarnessMonitorStore {
  @MainActor
  @Observable
  public final class ContentDashboardSlice {
    public var connectionState: ConnectionState = .idle
    public var isBusy = false
    public var isRefreshing = false
    public var isLaunchAgentInstalled = false
    public var notificationHistory: [NotificationHistoryEntry] = []
    public var auditEvents: [HarnessMonitorAuditEvent] = []
    public var auditHasOlder = false
    public var githubDataRevision: UInt64 = 0
    public var latestGitHubDataChange: GitHubDataChangedPayload?
    public var taskBoardRevision: UInt64 = 0
    /// True while a task-board-scoped mutation is in flight. Synced
    /// separately from `apply(_:)` via `applyTaskBoardBusy(_:)` since it is
    /// derived from store-internal counter state, not `ContentDashboardState`.
    public private(set) var isTaskBoardBusy = false
    /// Bumps only when `taskBoardItems` or `taskBoardOrchestratorStatus`
    /// actually changed during `apply(_:)`. Cheaper than whole-array
    /// equality for a `.task(id:)` key.
    public private(set) var taskBoardSnapshotRevision: UInt64 = 0
    public var taskBoardItems: [TaskBoardItem] = []
    public var taskBoardOrchestratorStatus: TaskBoardOrchestratorStatus?
    public var taskBoardAutomationSnapshot: TaskBoardAutomationSnapshot?
    public var taskBoardSyncSummary: TaskBoardSyncSummary?
    public var taskBoardDispatchSummary: TaskBoardDispatchSummary?
    public var taskBoardEvaluationSummary: TaskBoardEvaluationSummary?
    public var taskBoardEvaluationBaselineRunID: String?
    public var taskBoardItemAuditSummary: TaskBoardAuditSummary?
    public var taskBoardProjects: [TaskBoardProjectSummary]?
    public var taskBoardMachines: [TaskBoardMachineSummary]?
    public var policyCanvasWorkspace: PolicyCanvasWorkspace?
    public var policyPipeline: PolicyPipelineDocument?
    public var policySimulation: PolicyPipelineSimulationResult?
    public var policyAudit: PolicyPipelineAuditSummary?

    public init() {}

    internal func apply(_ state: ContentDashboardState) {
      Self.assign(&connectionState, state.connectionState)
      Self.assign(&isBusy, state.isBusy)
      Self.assign(&isRefreshing, state.isRefreshing)
      Self.assign(&isLaunchAgentInstalled, state.isLaunchAgentInstalled)
      Self.assign(&notificationHistory, state.notificationHistory)
      Self.assign(&auditEvents, state.auditEvents)
      Self.assign(&auditHasOlder, state.auditHasOlder)
      let didChangeTaskBoardItems = Self.assign(&taskBoardItems, state.taskBoardItems)
      let didChangeTaskBoardOrchestratorStatus = Self.assign(
        &taskBoardOrchestratorStatus,
        state.taskBoardOrchestratorStatus
      )
      if didChangeTaskBoardItems || didChangeTaskBoardOrchestratorStatus {
        taskBoardSnapshotRevision &+= 1
      }
      Self.assign(&taskBoardAutomationSnapshot, state.taskBoardAutomationSnapshot)
      Self.assign(&taskBoardSyncSummary, state.taskBoardSyncSummary)
      Self.assign(&taskBoardDispatchSummary, state.taskBoardDispatchSummary)
      Self.assign(&taskBoardEvaluationSummary, state.taskBoardEvaluationSummary)
      Self.assign(
        &taskBoardEvaluationBaselineRunID,
        state.taskBoardEvaluationBaselineRunID
      )
      Self.assign(&taskBoardItemAuditSummary, state.taskBoardItemAuditSummary)
      Self.assign(&taskBoardProjects, state.taskBoardProjects)
      Self.assign(&taskBoardMachines, state.taskBoardMachines)
      Self.assign(&policyCanvasWorkspace, state.policyCanvasWorkspace)
      Self.assign(&policyPipeline, state.policyPipeline)
      Self.assign(&policySimulation, state.policySimulation)
      Self.assign(&policyAudit, state.policyAudit)
    }

    /// Synced separately from `apply(_:)` because `isTaskBoardBusy` is
    /// derived from store-internal counter state rather than
    /// `ContentDashboardState`.
    internal func applyTaskBoardBusy(_ value: Bool) {
      Self.assign(&isTaskBoardBusy, value)
    }

    @discardableResult
    private static func assign<Value: Equatable>(_ current: inout Value, _ next: Value) -> Bool {
      guard current != next else { return false }
      current = next
      return true
    }
  }
}
