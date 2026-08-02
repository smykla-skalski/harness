import Foundation

public enum DashboardCodexContinuity: Equatable, Sendable {
  case attached(String)
  case restored(String)
  case completed(String)
  case stopped(String)
  case failed(String)
  case unavailable(String)

  public var title: String {
    switch self {
    case .attached: "Attached"
    case .restored: "Restored"
    case .completed: "Completed"
    case .stopped: "Stopped"
    case .failed: "Failed"
    case .unavailable: "Unavailable"
    }
  }

  public var detail: String {
    switch self {
    case .attached(let detail),
      .restored(let detail),
      .completed(let detail),
      .stopped(let detail),
      .failed(let detail),
      .unavailable(let detail):
      detail
    }
  }
}

public struct DashboardCodexAgentDetail: Equatable, Sendable {
  public let run: CodexRunSnapshot?
  public let inspect: CodexAgentInspectSnapshot?
  public let transcript: [TimelineEntry]
  public let issues: [String]
  public let refreshedAt: Date

  public init(
    run: CodexRunSnapshot?,
    inspect: CodexAgentInspectSnapshot?,
    transcript: [TimelineEntry],
    issues: [String],
    refreshedAt: Date = .now
  ) {
    self.run = run
    self.inspect = inspect
    self.transcript = transcript
    self.issues = issues
    self.refreshedAt = refreshedAt
  }

  public var pendingApprovals: [CodexApprovalRequest] { run?.pendingApprovals ?? [] }

  public var continuity: DashboardCodexContinuity {
    guard let run else {
      return .unavailable("The daemon did not return a current managed-agent record")
    }
    switch run.status {
    case .cancelled:
      return .stopped("The daemon reports this managed Codex run as stopped")
    case .completed:
      return .completed("The daemon persisted the completed run and its ordered transcript")
    case .failed:
      return .failed(
        run.error ?? "The daemon persisted a terminal Codex failure"
      )
    case .queued, .running, .waitingApproval:
      break
    }
    if inspect?.attached == true {
      return .attached("The current Codex turn is attached to this daemon")
    }
    if inspect != nil, run.threadId != nil {
      return .restored("The daemon restored the durable Codex thread and run state")
    }
    return .unavailable("No live attachment or persisted Codex thread proves continuity")
  }
}
