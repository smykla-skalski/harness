import Foundation

/// Mirrors the daemon's `WorkingCopyProgressEventPayload` wire shape sent over
/// the `task_board_working_copy_progress` WS push event.
///
/// Decoded once by the transport layer, then fanned out to per-repo
/// subscribers via `HarnessMonitorStore.observeWorkingCopyProgress`.
public struct TaskBoardWorkingCopyProgress: Equatable, Sendable, Codable {
  public enum Kind: String, Equatable, Sendable, Codable {
    case started
    case advanced
    case completed
    case failed
  }

  public let kind: Kind
  public let repoFullName: String
  /// gix's name for the phase in flight, such as "Receiving objects". Set only
  /// when `kind == .advanced`.
  public let phase: String?
  /// Set only when `kind == .advanced`.
  public let done: UInt64?
  /// Absent while the phase is unbounded, which gix reports until it learns the
  /// object count. Never set outside `.advanced`.
  public let total: UInt64?
  /// The daemon reports the phase as unable to advance. False is not a promise
  /// of health: an ordinary network stall keeps running with frozen counts, so
  /// treat a run of unchanged `done` values as the primary stall signal.
  public let blocked: Bool
  /// Set only when `kind == .completed`.
  public let durationMillis: UInt64?
  /// Set only when `kind == .failed`.
  public let message: String?

  public init(
    kind: Kind,
    repoFullName: String,
    phase: String? = nil,
    done: UInt64? = nil,
    total: UInt64? = nil,
    blocked: Bool = false,
    durationMillis: UInt64? = nil,
    message: String? = nil
  ) {
    self.kind = kind
    self.repoFullName = repoFullName
    self.phase = phase
    self.done = done
    self.total = total
    self.blocked = blocked
    self.durationMillis = durationMillis
    self.message = message
  }

  // Note: no explicit CodingKeys because `StreamEvent.decodePayload` runs its
  // decoder with `keyDecodingStrategy = .convertFromSnakeCase`. The default
  // member-name keys map `repoFullName` <- `repo_full_name` automatically; an
  // explicit `case repoFullName = "repo_full_name"` would *break* that mapping
  // by replacing the converted lookup key.
}

extension TaskBoardWorkingCopyProgress {
  /// Whether this event leaves the obtain in flight. Terminal events return the
  /// row to its resolved or retry state; the others keep the progress showing.
  public var isInFlight: Bool {
    switch kind {
    case .started, .advanced: true
    case .completed, .failed: false
    }
  }

  /// Completion in `0...1`, or nil when the phase is unbounded and no fraction
  /// can be claimed. A zero total is treated as unbounded rather than dividing
  /// by it.
  public var fractionCompleted: Double? {
    guard kind == .advanced, let done, let total, total > 0 else { return nil }
    return min(Double(done) / Double(total), 1)
  }

  /// One line describing the phase for a progress row, or nil when this event
  /// carries no phase to describe.
  public var phaseLabel: String? {
    guard kind == .advanced, let phase else { return nil }
    guard let done else { return phase }
    guard let total, total > 0 else { return "\(phase) \(done)" }
    return "\(phase) \(done)/\(total)"
  }
}
