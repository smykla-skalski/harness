import Foundation

public struct TaskBoardStatusCount: Codable, Equatable, Sendable {
  public let status: TaskBoardStatus
  public let count: Int
}

public enum TaskBoardExternalProvider: String, Codable, Sendable {
  case gitHub = "git_hub"
  case todoist
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
}

public struct TaskBoardAuditSummary: Codable, Equatable, Sendable {
  public let total: Int
  public let ready: Int
  public let blocked: Int
  public let deleted: Int
  public let byStatus: [TaskBoardStatusCount]
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

public struct TaskBoardPolicyDecision: Codable, Equatable, Sendable {
  public let decision: String
  public let reasonCode: String
  public let policyVersion: String

  public init(
    decision: String,
    reasonCode: String,
    policyVersion: String
  ) {
    self.decision = decision
    self.reasonCode = reasonCode
    self.policyVersion = policyVersion
  }
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
