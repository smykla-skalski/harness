import Foundation

public struct ActionFeedback: Identifiable, Equatable, Hashable, Sendable {
  public enum Severity: Sendable, Hashable {
    case success
    case failure
    case undoable
  }

  public let id: UUID
  public let message: String
  public let severity: Severity
  public let accessibilityIdentifier: String?
  public var repeatCount: Int
  public var issuedAt: ContinuousClock.Instant
  public var pausedRemaining: Duration?

  public init(
    id: UUID = UUID(),
    message: String,
    severity: Severity,
    accessibilityIdentifier: String? = nil,
    repeatCount: Int = 1,
    issuedAt: ContinuousClock.Instant,
    pausedRemaining: Duration? = nil
  ) {
    self.id = id
    self.message = message
    self.severity = severity
    self.accessibilityIdentifier = accessibilityIdentifier
    self.repeatCount = repeatCount
    self.issuedAt = issuedAt
    self.pausedRemaining = pausedRemaining
  }
}
