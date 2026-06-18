import Foundation

public struct TaskBoardStatusCount: Codable, Equatable, Sendable {
  public let status: TaskBoardStatus
  public let count: Int
}

public enum TaskBoardExternalProvider: String, Codable, Sendable {
  case gitHub = "git_hub"
  case todoist
}

public enum TaskBoardExternalSyncAction: String, Codable, CaseIterable, Sendable {
  case pull
  case push
  // The daemon's ExternalSyncAction also emits conflict/delete on real sync runs; modelling them
  // keeps a populated operations list from failing to decode.
  case conflict
  case delete
}

public struct TaskBoardProviderSyncSummary: Codable, Equatable, Sendable {
  public let provider: TaskBoardExternalProvider
  public let configured: Bool
  public let linked: Int
  public let pushable: Int
  public let blocked: Int
  public let tokenEnv: [String]
}

public struct TaskBoardSyncSummary: Codable, Equatable, Sendable {
  public let total: Int
  public let providers: [TaskBoardProviderSyncSummary]
  public let operations: [TaskBoardExternalSyncOperation]

  public init(
    total: Int,
    providers: [TaskBoardProviderSyncSummary],
    operations: [TaskBoardExternalSyncOperation] = []
  ) {
    self.total = total
    self.providers = providers
    self.operations = operations
  }

  enum CodingKeys: String, CodingKey {
    case total
    case providers
    case operations
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    total = try container.decode(Int.self, forKey: .total)
    providers = try container.decode([TaskBoardProviderSyncSummary].self, forKey: .providers)
    operations =
      try container.decodeIfPresent([TaskBoardExternalSyncOperation].self, forKey: .operations)
      ?? []
  }
}

public struct TaskBoardExternalSyncOperation: Codable, Equatable, Sendable {
  public let provider: TaskBoardExternalProvider
  public let action: TaskBoardExternalSyncAction
  public let boardItemId: String?
  public let externalId: String?
  public let url: String?
  public let dryRun: Bool
  public let applied: Bool

  public init(
    provider: TaskBoardExternalProvider,
    action: TaskBoardExternalSyncAction,
    boardItemId: String? = nil,
    externalId: String? = nil,
    url: String? = nil,
    dryRun: Bool,
    applied: Bool
  ) {
    self.provider = provider
    self.action = action
    self.boardItemId = boardItemId
    self.externalId = externalId
    self.url = url
    self.dryRun = dryRun
    self.applied = applied
  }
}

public struct TaskBoardAuditSummary: Codable, Equatable, Sendable {
  public let total: Int
  public let ready: Int
  public let blocked: Int
  public let deleted: Int
  public let byStatus: [TaskBoardStatusCount]
}

public struct TaskBoardProjectSummary: Codable, Equatable, Identifiable, Sendable {
  public let projectId: String
  public let itemCount: Int
  public let readyCount: Int

  public var id: String { projectId }
}

public struct TaskBoardMachineSummary: Codable, Equatable, Identifiable, Sendable {
  public let mode: TaskBoardAgentMode
  public let itemCount: Int
  public let readyCount: Int

  public var id: TaskBoardAgentMode { mode }
}

public struct TaskBoardDispatchPlan: Codable, Equatable, Identifiable, Sendable {
  public let boardItemId: String
  public let readiness: TaskBoardDispatchReadiness
  public let session: TaskBoardSessionIntent
  public let task: TaskBoardTaskCreationIntent
  public let worker: TaskBoardWorkerIntent
  public let reviewer: TaskBoardReviewerIntent
  public let evaluator: TaskBoardEvaluatorIntent
  public let policy: TaskBoardPolicyDecision?

  public var id: String { boardItemId }
}

public struct TaskBoardDispatchSummary: Codable, Equatable, Sendable {
  public let plans: [TaskBoardDispatchPlan]
  public let applied: [TaskBoardDispatchAppliedTask]
}

public struct TaskBoardDispatchAppliedTask: Codable, Equatable, Identifiable, Sendable {
  public let boardItemId: String
  public let sessionId: String
  public let workItemId: String
  public let item: TaskBoardItem

  public var id: String { boardItemId }
}

public struct TaskBoardDispatchReadiness: Codable, Equatable, Sendable {
  public let state: String
  public let reason: TaskBoardDispatchBlockReason?

  public var isReady: Bool { state == "ready" }
}

public struct TaskBoardDispatchBlockReason: Codable, Equatable, Sendable {
  public let kind: String
  public let workItemId: String?
  public let reason: TaskBoardPlanApprovalBlockReason?
  public let decision: TaskBoardPolicyDecision?
  public let status: TaskBoardStatus?
}

public enum TaskBoardPlanApprovalBlockReason: String, Codable, Sendable {
  case deleted
  case missingSummary = "missing_summary"
  case missingApprover = "missing_approver"
  case missingApprovalTime = "missing_approval_time"
}

public struct TaskBoardSessionIntent: Codable, Equatable, Sendable {
  public let kind: String
  public let sessionId: String?
  public let title: String?
  public let context: String?
  public let projectId: String?
}

public struct TaskBoardTaskCreationIntent: Codable, Equatable, Sendable {
  public let title: String
  public let context: String?
  public let severity: TaskSeverity
  public let suggestedFix: String?
  public let source: TaskSource
  public let tags: [String]
  public let externalRefs: [TaskBoardExternalRef]
}

public struct TaskBoardWorkerIntent: Codable, Equatable, Sendable {
  public let mode: TaskBoardAgentMode
}

public struct TaskBoardReviewerIntent: Codable, Equatable, Sendable {
  public let phase: String
  public let suggestedPersona: String
  public let requiredConsensus: UInt8
}

public struct TaskBoardEvaluatorIntent: Codable, Equatable, Sendable {
  public let phase: String
  public let mode: TaskBoardAgentMode
}
