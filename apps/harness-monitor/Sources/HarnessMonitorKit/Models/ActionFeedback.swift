import Foundation

public struct ActionFeedbackAction: Equatable, Hashable, Sendable {
  public enum Kind: Equatable, Hashable, Sendable {
    case copy(text: String)
  }

  public let title: String
  public let systemImage: String
  public let kind: Kind
  public let successAnnouncement: String

  public init(
    title: String,
    systemImage: String,
    kind: Kind,
    successAnnouncement: String
  ) {
    self.title = title
    self.systemImage = systemImage
    self.kind = kind
    self.successAnnouncement = successAnnouncement
  }
}

public struct ActionFeedbackDetails: Equatable, Hashable, Sendable {
  public let disclosureLabel: String
  public let summary: String?
  public let rows: [ActionFeedbackDetailRow]
  public let command: String?

  public init(
    disclosureLabel: String = "details",
    summary: String? = nil,
    rows: [ActionFeedbackDetailRow] = [],
    command: String? = nil
  ) {
    self.disclosureLabel = disclosureLabel
    self.summary = summary?.harnessMonitorTrimmedTrailingPeriod
    self.rows = rows
    self.command = command
  }
}

public struct ActionFeedbackDetailRow: Equatable, Hashable, Sendable {
  public let label: String
  public let value: String

  public init(label: String, value: String) {
    self.label = label
    self.value = value
  }
}

public struct ActionFeedback: Identifiable, Equatable, Hashable, Sendable {
  public enum Severity: Sendable, Hashable {
    case success
    case warning
    case failure
    case undoable
  }

  public enum Position: String, Codable, CaseIterable, Sendable, Hashable {
    case topTrailing
    case bottomTrailing
  }

  public let id: UUID
  public let title: String?
  public let message: String
  public let severity: Severity
  public let details: ActionFeedbackDetails?
  public let primaryAction: ActionFeedbackAction?
  public let accessibilityIdentifier: String?
  public let position: Position
  public var repeatCount: Int
  public var issuedAt: ContinuousClock.Instant
  public var pausedRemaining: Duration?

  public init(
    id: UUID = UUID(),
    title: String? = nil,
    message: String,
    severity: Severity,
    details: ActionFeedbackDetails? = nil,
    primaryAction: ActionFeedbackAction? = nil,
    accessibilityIdentifier: String? = nil,
    position: Position = .topTrailing,
    repeatCount: Int = 1,
    issuedAt: ContinuousClock.Instant,
    pausedRemaining: Duration? = nil
  ) {
    self.id = id
    self.title = title
    self.message = message.harnessMonitorTrimmedTrailingPeriod
    self.severity = severity
    self.details = details
    self.primaryAction = primaryAction
    self.accessibilityIdentifier = accessibilityIdentifier
    self.position = position
    self.repeatCount = repeatCount
    self.issuedAt = issuedAt
    self.pausedRemaining = pausedRemaining
  }

  public var announcementText: String {
    if let title {
      return "\(title). \(message)"
    }
    return message
  }
}
