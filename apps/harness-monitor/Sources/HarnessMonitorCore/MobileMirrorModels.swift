import Foundation

public enum MobileStationState: String, Codable, CaseIterable, Sendable {
  case online
  case stale
  case offline

  public var title: String {
    switch self {
    case .online: "Online"
    case .stale: "Stale"
    case .offline: "Offline"
    }
  }
}

public enum MobileAttentionSeverity: String, Codable, CaseIterable, Sendable {
  case info
  case warning
  case critical

  public var rank: Int {
    switch self {
    case .critical: 0
    case .warning: 1
    case .info: 2
    }
  }

  public var title: String {
    switch self {
    case .info: "Info"
    case .warning: "Warning"
    case .critical: "Critical"
    }
  }
}

public enum MobileAttentionKind: String, Codable, CaseIterable, Sendable {
  case acpDecision
  case pullRequest
  case taskBoard
  case blockedAgent
  case commandFailure
  case stationHealth

  public var title: String {
    switch self {
    case .acpDecision: "ACP Decision"
    case .pullRequest: "Pull Request"
    case .taskBoard: "Task Board"
    case .blockedAgent: "Blocked Agent"
    case .commandFailure: "Command Failure"
    case .stationHealth: "Station Health"
    }
  }
}

public enum MobileCommandKind: String, Codable, CaseIterable, Sendable {
  case acpPermissionDecision
  case taskBoardDispatch
  case taskBoardPlanApproval
  case agentStart
  case agentStop
  case agentPrompt
  case pullRequestApprove
  case pullRequestLabel
  case pullRequestRerunChecks
  case pullRequestMerge
  case refresh

  public var title: String {
    switch self {
    case .acpPermissionDecision: "Resolve Permission"
    case .taskBoardDispatch: "Dispatch Task"
    case .taskBoardPlanApproval: "Approve Plan"
    case .agentStart: "Start Agent"
    case .agentStop: "Stop Agent"
    case .agentPrompt: "Prompt Agent"
    case .pullRequestApprove: "Approve PR"
    case .pullRequestLabel: "Label PR"
    case .pullRequestRerunChecks: "Rerun Checks"
    case .pullRequestMerge: "Merge PR"
    case .refresh: "Refresh"
    }
  }

  public var risk: MobileCommandRisk {
    switch self {
    case .pullRequestMerge:
      .destructive
    case .pullRequestRerunChecks, .refresh:
      .low
    case .acpPermissionDecision, .taskBoardDispatch, .taskBoardPlanApproval, .agentStart,
      .agentStop, .agentPrompt, .pullRequestApprove, .pullRequestLabel:
      .high
    }
  }
}

public enum MobileCommandRisk: String, Codable, CaseIterable, Sendable {
  case low
  case high
  case destructive

  public var requiresFreshState: Bool {
    self != .low
  }
}

public enum MobileCommandStatus: String, Codable, CaseIterable, Sendable {
  case draft
  case queued
  case accepted
  case running
  case succeeded
  case failed
  case expired
  case cancelled

  public var isTerminal: Bool {
    switch self {
    case .succeeded, .failed, .expired, .cancelled:
      true
    case .draft, .queued, .accepted, .running:
      false
    }
  }

  public var title: String {
    switch self {
    case .draft: "Draft"
    case .queued: "Queued"
    case .accepted: "Accepted"
    case .running: "Running"
    case .succeeded: "Succeeded"
    case .failed: "Failed"
    case .expired: "Expired"
    case .cancelled: "Cancelled"
    }
  }
}
