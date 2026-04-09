import Foundation

public enum CodexRunMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case report
  case workspaceWrite = "workspace_write"
  case approval

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .report:
      "Report"
    case .workspaceWrite:
      "Workspace Write"
    case .approval:
      "Approval"
    }
  }
}

public enum CodexRunStatus: String, Codable, Sendable {
  case queued
  case running
  case waitingApproval = "waiting_approval"
  case completed
  case failed
  case cancelled

  public var title: String {
    switch self {
    case .queued:
      "Queued"
    case .running:
      "Running"
    case .waitingApproval:
      "Waiting Approval"
    case .completed:
      "Completed"
    case .failed:
      "Failed"
    case .cancelled:
      "Cancelled"
    }
  }

  public var isActive: Bool {
    switch self {
    case .queued, .running, .waitingApproval:
      true
    case .completed, .failed, .cancelled:
      false
    }
  }
}

public enum CodexApprovalDecision: String, Codable, CaseIterable, Sendable {
  case accept
  case acceptForSession = "accept_for_session"
  case decline
  case cancel
}

public struct CodexRunRequest: Codable, Equatable, Sendable {
  public let actor: String?
  public let prompt: String
  public let mode: CodexRunMode
  public let resumeThreadId: String?

  public init(
    actor: String?,
    prompt: String,
    mode: CodexRunMode,
    resumeThreadId: String? = nil
  ) {
    self.actor = actor
    self.prompt = prompt
    self.mode = mode
    self.resumeThreadId = resumeThreadId
  }
}

public struct CodexSteerRequest: Codable, Equatable, Sendable {
  public let prompt: String
}

public struct CodexApprovalDecisionRequest: Codable, Equatable, Sendable {
  public let decision: CodexApprovalDecision
}

public struct CodexRunListResponse: Codable, Equatable, Sendable {
  public let runs: [CodexRunSnapshot]
}

public struct CodexApprovalRequest: Codable, Equatable, Identifiable, Sendable {
  public let approvalId: String
  public let requestId: String
  public let kind: String
  public let title: String
  public let detail: String
  public let threadId: String?
  public let turnId: String?
  public let itemId: String?
  public let cwd: String?
  public let command: String?
  public let filePath: String?

  public var id: String { approvalId }
}

public struct CodexRunSnapshot: Codable, Equatable, Identifiable, Sendable {
  public let runId: String
  public let sessionId: String
  public let projectDir: String
  public let threadId: String?
  public let turnId: String?
  public let mode: CodexRunMode
  public let status: CodexRunStatus
  public let prompt: String
  public let latestSummary: String?
  public let finalMessage: String?
  public let error: String?
  public let pendingApprovals: [CodexApprovalRequest]
  public let createdAt: String
  public let updatedAt: String

  public var id: String { runId }
}

public struct CodexApprovalRequestedPayload: Codable, Equatable, Sendable {
  public let run: CodexRunSnapshot
  public let approval: CodexApprovalRequest
}
