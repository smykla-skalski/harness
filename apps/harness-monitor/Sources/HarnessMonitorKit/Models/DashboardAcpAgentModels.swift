import Foundation

public enum DashboardAcpContinuity: Equatable, Sendable {
  case resumable(String)
  case recoverable(String)
  case stopped(String)
  case unavailable(String)

  public var title: String {
    switch self {
    case .resumable: "Resumable"
    case .recoverable: "Recoverable"
    case .stopped: "Stopped"
    case .unavailable: "Unavailable"
    }
  }

  public var detail: String {
    switch self {
    case .resumable(let detail),
      .recoverable(let detail),
      .stopped(let detail),
      .unavailable(let detail):
      detail
    }
  }
}

public struct DashboardAcpAgentDetail: Equatable, Sendable {
  public let agent: AcpAgentSnapshot?
  public let inspect: AcpAgentInspectSnapshot?
  public let transcript: [TimelineEntry]
  public let providerSessions: [AcpProviderSession]
  public let issues: [String]
  public let refreshedAt: Date

  public init(
    agent: AcpAgentSnapshot?,
    inspect: AcpAgentInspectSnapshot?,
    transcript: [TimelineEntry],
    providerSessions: [AcpProviderSession],
    issues: [String],
    refreshedAt: Date = .now
  ) {
    self.agent = agent
    self.inspect = inspect
    self.transcript = transcript
    self.providerSessions = providerSessions
    self.issues = issues
    self.refreshedAt = refreshedAt
  }

  public var handshake: AcpAgentHandshake? { inspect?.handshake }
  public var sessionState: AcpAgentSessionState? { inspect?.sessionState }
  public var pendingPermissions: [AcpPermissionBatch] { agent?.pendingPermissionBatches ?? [] }

  public var continuity: DashboardAcpContinuity {
    guard let agent else {
      return .unavailable("The daemon did not return a current managed-agent record")
    }
    if agent.status == .removed {
      return .stopped("The daemon reports this managed agent as stopped")
    }
    if let handshake, handshake.supportsSessionResume, sessionState != nil {
      return .resumable("The adapter reports resume support and persisted provider session state")
    }
    if agent.isRestartable, let handshake,
      handshake.supportsLoadSession || handshake.supportsSessionResume
    {
      return .recoverable("The exit is restartable and the adapter can load provider sessions")
    }
    return .unavailable(
      "No persisted adapter evidence proves that this provider session can resume"
    )
  }
}
