import Foundation

struct SelectedTimelineLoadState {
  var pageLoadTask: Task<Void, Never>?
  var pageLoadKey: SelectedTimelinePageLoadKey?
  var pageLoadSequence: UInt64 = 0
  var preferredWindowLimit: Int?
  var windowLoadTask: Task<Void, Never>?
  var windowLoadKey: SelectedTimelineWindowLoadKey?
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
