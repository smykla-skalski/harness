import Foundation

public enum MobileStationState: String, Codable, CaseIterable, Sendable {
  case online
  case stale
  case offline

  public var title: String {
    switch self {
    case .online: String(localized: "Online", bundle: .module)
    case .stale: String(localized: "Stale", bundle: .module)
    case .offline: String(localized: "Offline", bundle: .module)
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
    case .info: String(localized: "Info", bundle: .module)
    case .warning: String(localized: "Warning", bundle: .module)
    case .critical: String(localized: "Critical", bundle: .module)
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
    case .acpDecision: String(localized: "ACP Decision", bundle: .module)
    case .pullRequest: String(localized: "Pull Request", bundle: .module)
    case .taskBoard: String(localized: "Task board", bundle: .module)
    case .blockedAgent: String(localized: "Blocked Agent", bundle: .module)
    case .commandFailure: String(localized: "Command Failure", bundle: .module)
    case .stationHealth: String(localized: "Station health", bundle: .module)
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
    case .acpPermissionDecision: String(localized: "Resolve Permission", bundle: .module)
    case .taskBoardDispatch: String(localized: "Dispatch Task", bundle: .module)
    case .taskBoardPlanApproval: String(localized: "Approve Plan", bundle: .module)
    case .agentStart: String(localized: "Start Agent", bundle: .module)
    case .agentStop: String(localized: "Stop Agent", bundle: .module)
    case .agentPrompt: String(localized: "Prompt Agent", bundle: .module)
    case .pullRequestApprove: String(localized: "Approve PR", bundle: .module)
    case .pullRequestLabel: String(localized: "Label PR", bundle: .module)
    case .pullRequestRerunChecks: String(localized: "Rerun Checks", bundle: .module)
    case .pullRequestMerge: String(localized: "Merge PR", bundle: .module)
    case .refresh: String(localized: "Refresh", bundle: .module)
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
    case .draft: String(localized: "Draft", bundle: .module)
    case .queued: String(localized: "Queued", bundle: .module)
    case .accepted: String(localized: "Accepted", bundle: .module)
    case .running: String(localized: "Running", bundle: .module)
    case .succeeded: String(localized: "Succeeded", bundle: .module)
    case .failed: String(localized: "Failed", bundle: .module)
    case .expired: String(localized: "Expired", bundle: .module)
    case .cancelled: String(localized: "Cancelled", bundle: .module)
    }
  }
}
