import Foundation

extension DaemonPushEvent {
  /// Returns `nil` for an event outside this group, so the caller falls
  /// through to the next group rather than treating "not this kind" as a
  /// terminal decode failure.
  static func makeDataChangedEvent(from streamEvent: StreamEvent) throws -> Self? {
    let at = streamEvent.recordedAt
    switch streamEvent.event {
    case "reviews_local_clone_progress":
      return Self(
        recordedAt: at,
        sessionId: nil,
        kind: .reviewsLocalCloneProgress(
          ReviewLocalCloneProgress(
            wire: try streamEvent.decodePayloadWire(as: LocalCloneProgressEventPayloadWire.self)
          )
        )
      )
    case "task_board_working_copy_progress":
      return Self(
        recordedAt: at,
        sessionId: nil,
        kind: .taskBoardWorkingCopyProgress(
          TaskBoardWorkingCopyProgress(
            wire: try streamEvent.decodePayloadWire(as: WorkingCopyProgressEventPayloadWire.self)
          )
        )
      )
    case "github_data_changed":
      return Self(
        recordedAt: at,
        sessionId: nil,
        kind: .githubDataChanged(
          try streamEvent.decodePayloadWire(as: GitHubDataChangedPayload.self)
        )
      )
    case "task_board_updated":
      return Self(
        recordedAt: at,
        sessionId: nil,
        kind: .taskBoardUpdated(
          try streamEvent.decodePayloadWire(as: TaskBoardUpdatedPayload.self)
        )
      )
    case "audit_event":
      return Self(
        recordedAt: at,
        sessionId: nil,
        kind: .auditEvent(
          try HarnessMonitorAuditEvent(
            wire: streamEvent.decodePayloadWire(as: HarnessMonitorAuditEventWire.self)))
      )
    default:
      return nil
    }
  }
}
