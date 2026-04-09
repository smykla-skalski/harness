import Foundation

public enum HarnessMonitorPushEventError: Error, LocalizedError, Equatable {
  case missingSessionID(String)

  public var errorDescription: String? {
    switch self {
    case .missingSessionID(let event):
      "Missing session ID for daemon push event '\(event)'."
    }
  }
}

public struct DaemonPushEvent: Equatable, Identifiable, Sendable {
  public enum Kind: Equatable, Sendable {
    case ready
    case sessionsUpdated(SessionsUpdatedPayload)
    case sessionUpdated(SessionUpdatedPayload)
    case sessionExtensions(SessionExtensionsPayload)
    case logLevelChanged(LogLevelResponse)
    case codexRunUpdated(CodexRunSnapshot)
    case codexApprovalRequested(CodexApprovalRequestedPayload)
    case unknown(eventName: String, payload: JSONValue)
  }

  public let recordedAt: String
  public let sessionId: String?
  public let kind: Kind
  private let stableID: UUID

  public var id: UUID { stableID }

  public init(
    recordedAt: String,
    sessionId: String?,
    kind: Kind,
    stableID: UUID = UUID()
  ) {
    self.recordedAt = recordedAt
    self.sessionId = sessionId
    self.kind = kind
    self.stableID = stableID
  }

  public init(streamEvent: StreamEvent) throws {
    self = try Self.make(from: streamEvent)
  }

  private static func make(from streamEvent: StreamEvent) throws -> Self {
    let at = streamEvent.recordedAt
    switch streamEvent.event {
    case "ready":
      return Self(recordedAt: at, sessionId: streamEvent.sessionId, kind: .ready)
    case "sessions_updated":
      return Self(
        recordedAt: at,
        sessionId: nil,
        kind: .sessionsUpdated(try streamEvent.decodePayload(as: SessionsUpdatedPayload.self))
      )
    case "log_level_changed":
      return Self(
        recordedAt: at,
        sessionId: nil,
        kind: .logLevelChanged(try streamEvent.decodePayload(as: LogLevelResponse.self))
      )
    default:
      return try Self.makeSessionScopedEvent(from: streamEvent)
    }
  }

  private static func makeSessionScopedEvent(from streamEvent: StreamEvent) throws -> Self {
    guard let sessionId = streamEvent.sessionId else {
      throw HarnessMonitorPushEventError.missingSessionID(streamEvent.event)
    }
    let at = streamEvent.recordedAt
    switch streamEvent.event {
    case "session_updated":
      return Self(
        recordedAt: at,
        sessionId: sessionId,
        kind: .sessionUpdated(try streamEvent.decodePayload(as: SessionUpdatedPayload.self))
      )
    case "session_extensions":
      return Self(
        recordedAt: at,
        sessionId: sessionId,
        kind: .sessionExtensions(
          try streamEvent.decodePayload(as: SessionExtensionsPayload.self)
        )
      )
    case "codex_run_updated":
      return Self(
        recordedAt: at,
        sessionId: sessionId,
        kind: .codexRunUpdated(try streamEvent.decodePayload(as: CodexRunSnapshot.self))
      )
    case "codex_approval_requested":
      return Self(
        recordedAt: at,
        sessionId: sessionId,
        kind: .codexApprovalRequested(
          try streamEvent.decodePayload(as: CodexApprovalRequestedPayload.self)
        )
      )
    default:
      return Self(
        recordedAt: at,
        sessionId: sessionId,
        kind: .unknown(eventName: streamEvent.event, payload: streamEvent.payload)
      )
    }
  }

  public static func ready(
    recordedAt: String,
    sessionId: String? = nil
  ) -> Self {
    Self(recordedAt: recordedAt, sessionId: sessionId, kind: .ready)
  }

  public static func sessionsUpdated(
    recordedAt: String,
    projects: [ProjectSummary],
    sessions: [SessionSummary]
  ) -> Self {
    Self(
      recordedAt: recordedAt,
      sessionId: nil,
      kind: .sessionsUpdated(
        SessionsUpdatedPayload(projects: projects, sessions: sessions)
      )
    )
  }

  public static func sessionUpdated(
    recordedAt: String,
    sessionId: String,
    detail: SessionDetail,
    timeline: [TimelineEntry]? = nil,
    extensionsPending: Bool? = nil
  ) -> Self {
    Self(
      recordedAt: recordedAt,
      sessionId: sessionId,
      kind: .sessionUpdated(
        SessionUpdatedPayload(
          detail: detail,
          timeline: timeline,
          extensionsPending: extensionsPending
        )
      )
    )
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.recordedAt == rhs.recordedAt
      && lhs.sessionId == rhs.sessionId
      && lhs.kind == rhs.kind
  }
}
