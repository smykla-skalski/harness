import Foundation

// Static factory methods and Equatable conformance for DaemonPushEvent.
extension DaemonPushEvent {
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

  public static func sessionsUpdatedDelta(
    recordedAt: String,
    sessionId: String? = nil,
    changed: [SessionSummary],
    removed: [String],
    projects: [ProjectSummary]
  ) -> Self {
    Self(
      recordedAt: recordedAt,
      sessionId: sessionId,
      kind: .sessionsUpdatedDelta(
        SessionsUpdatedDeltaPayload(changed: changed, removed: removed, projects: projects)
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
