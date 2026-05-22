import Foundation

/// Mirrors the daemon's `LocalCloneProgressEventPayload` wire shape sent
/// over the `reviews_local_clone_progress` WS push event.
///
/// Decoded once by the transport layer, then fanned out to per-repo
/// subscribers via `HarnessMonitorStore.observeLocalCloneProgress`.
public struct ReviewLocalCloneProgress: Equatable, Sendable, Codable {
  public enum Kind: String, Equatable, Sendable, Codable {
    case started
    case completed
    case failed
  }

  public enum Operation: String, Equatable, Sendable, Codable {
    case clone
    case fetch

    /// Short verb-form label the Settings sheet can render directly:
    /// "Cloning" / "Fetching".
    public var presentLabel: String {
      switch self {
      case .clone: return "Cloning"
      case .fetch: return "Fetching"
      }
    }
  }

  public let kind: Kind
  public let repoFullName: String
  public let operation: Operation
  /// Set only when `kind == .completed`.
  public let durationMillis: UInt64?
  /// Set only when `kind == .failed`.
  public let message: String?

  public init(
    kind: Kind,
    repoFullName: String,
    operation: Operation,
    durationMillis: UInt64? = nil,
    message: String? = nil
  ) {
    self.kind = kind
    self.repoFullName = repoFullName
    self.operation = operation
    self.durationMillis = durationMillis
    self.message = message
  }

  // Note: no explicit CodingKeys because `StreamEvent.decodePayload` runs
  // its decoder with `keyDecodingStrategy = .convertFromSnakeCase`. The
  // default member-name keys map `repoFullName` <- `repo_full_name`
  // automatically; an explicit `case repoFullName = "repo_full_name"`
  // would *break* that mapping by replacing the converted lookup key.
}

extension ReviewLocalCloneProgress {
  /// JSON decoder configured to consume the daemon's snake_case wire
  /// shape directly. Mirrors the strategy used by `StreamEvent.decodePayload`
  /// so direct-from-raw-JSON tests pass without going through the
  /// `StreamEvent` wrapper.
  public static func snakeCaseDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }
}
