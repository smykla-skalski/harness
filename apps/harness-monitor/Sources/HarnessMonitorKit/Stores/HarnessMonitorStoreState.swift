import Foundation

struct CacheWriteSyncState {
  var taskBoardRefreshTask: Task<Void, Never>?
  var taskBoardRefreshGeneration: UInt64 = 0
  var taskBoardRefreshRequestGeneration: UInt64 = 0
  var taskBoardRefreshCompletedGeneration: UInt64 = 0
  var taskBoardRefreshDeferralDepth = 0
  var taskBoardRefreshCompletionWaiters: [UInt64: [CheckedContinuation<Void, Never>]] = [:]
  var pendingTaskBoardItemsRefresh = false
  var pendingTaskBoardOrchestratorRefresh = false
  var pendingTaskBoardFallbackStatus: TaskBoardOrchestratorStatus?
  var taskBoardEvaluationBaselineRunID: String?
  var pendingCacheWriteTask: Task<Void, Never>?
  var pendingCacheWriteTaskToken: UInt64 = 0
  var pendingTaskBoardSnapshotCacheWriteTask: Task<Void, Never>?
  var taskBoardSnapshotCacheWriteToken: UInt64 = 0
  var pendingSessionDetailCacheWriteTask: Task<Void, Never>?
  var pendingSessionDetailCacheWriteTaskToken: UInt64 = 0
  var pendingSessionDetailCacheWrites: [String: PendingSessionDetailCacheWrite] = [:]
}

struct SelectedTimelineLoadState {
  var pageLoadTask: Task<Void, Never>?
  var pageLoadKey: HarnessMonitorStore.SelectedTimelinePageLoadKey?
  var pageLoadSequence: UInt64 = 0
  var preferredWindowLimit: Int?
  var windowLoadTask: Task<Void, Never>?
  var windowLoadKey: HarnessMonitorStore.SelectedTimelineWindowLoadKey?
  var windowLoadSequence: UInt64 = 0
}

struct AcpPermissionSyncState {
  var decisionSyncTask: Task<Void, Never>?
  var decisionSyncGeneration: UInt64 = 0
  var deadlineResolutionTasks: [String: Task<Void, Never>] = [:]
  var deadlineResolutionTokens: [String: UInt64] = [:]
  var shutdownResolutionTasks: [String: Task<Void, Never>] = [:]
  var shutdownResolutionTokens: [String: UInt64] = [:]
}

struct AcpTimelineSyncState {
  var mergeTask: Task<Void, Never>?
  var mergeGeneration: UInt64 = 0
  var transcriptMergeTask: Task<Void, Never>?
  var transcriptMergeGeneration: UInt64 = 0
  var transcriptLiveMergeTask: Task<Void, Never>?
  var transcriptLiveMergeGeneration: UInt64 = 0
  var transcriptHistoryTask: Task<Void, Never>?
  var transcriptHistoryGeneration: UInt64 = 0
  var reattributeTask: Task<Void, Never>?
  var reattributeGeneration: UInt64 = 0
  var transcriptReattributeTask: Task<Void, Never>?
  var transcriptReattributeGeneration: UInt64 = 0
  var transcriptPartitionTask: Task<Void, Never>?
  var transcriptPartitionGeneration: UInt64 = 0
}
