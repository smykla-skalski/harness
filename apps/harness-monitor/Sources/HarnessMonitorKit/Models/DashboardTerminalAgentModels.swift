import Foundation

public enum DashboardTerminalStartOutcome: Equatable, Sendable {
  case started(AgentTuiSnapshot)
  case rejected(String)
  case unknown(String)

  public var snapshot: AgentTuiSnapshot? {
    guard case .started(let snapshot) = self else { return nil }
    return snapshot
  }
}

public enum DashboardTerminalContinuity: Equatable, Sendable {
  case starting(String)
  case attached(String)
  case completed(String)
  case stopped(String)
  case failed(String)
  case unavailable(String)

  public var title: String {
    switch self {
    case .starting: "Starting"
    case .attached: "Attached"
    case .completed: "Completed"
    case .stopped: "Stopped"
    case .failed: "Failed"
    case .unavailable: "Unavailable"
    }
  }

  public var detail: String {
    switch self {
    case .starting(let detail),
      .attached(let detail),
      .completed(let detail),
      .stopped(let detail),
      .failed(let detail),
      .unavailable(let detail):
      detail
    }
  }
}

public struct DashboardTerminalAgentDetail: Equatable, Sendable {
  public let snapshot: AgentTuiSnapshot?
  public let isMember: Bool?
  public let issues: [String]
  public let refreshedAt: Date

  public init(
    snapshot: AgentTuiSnapshot?,
    isMember: Bool? = nil,
    issues: [String],
    refreshedAt: Date = .now
  ) {
    self.snapshot = snapshot
    self.isMember = isMember
    self.issues = issues
    self.refreshedAt = refreshedAt
  }

  public var continuity: DashboardTerminalContinuity {
    guard let snapshot else {
      return .unavailable("The daemon did not return a current managed terminal record")
    }
    switch snapshot.status {
    case .starting:
      return .starting("The daemon accepted the terminal start and is waiting for readiness")
    case .running:
      return .attached("The daemon reconciled this identity with a live terminal process")
    case .stopped:
      return .stopped("The daemon reports this managed terminal as stopped")
    case .exited:
      return .completed("The daemon preserved the terminal outcome after process exit")
    case .failed:
      return .failed(snapshot.error ?? "The daemon preserved a terminal process failure")
    }
  }
}
