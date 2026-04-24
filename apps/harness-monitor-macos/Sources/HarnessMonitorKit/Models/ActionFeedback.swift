import Foundation

public struct ActionFeedback: Identifiable, Equatable, Hashable, Sendable {
  public enum Severity: Sendable, Hashable {
    case success
    case failure
  }

  public let id: UUID
  public let message: String
  public let severity: Severity
  public let accessibilityIdentifier: String?
  public var issuedAt: ContinuousClock.Instant
  public var pausedRemaining: Duration?

  public init(
    id: UUID = UUID(),
    message: String,
    severity: Severity,
    accessibilityIdentifier: String? = nil,
    issuedAt: ContinuousClock.Instant,
    pausedRemaining: Duration? = nil
  ) {
    self.id = id
    self.message = message
    self.severity = severity
    self.accessibilityIdentifier = accessibilityIdentifier
    self.issuedAt = issuedAt
    self.pausedRemaining = pausedRemaining
  }
}
