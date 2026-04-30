import Foundation

public enum AcpPermissionDeadlinePhase: Equatable, Sendable {
  case pending
  case expiring
  case expired
  case stale
}

public struct AcpPermissionDeadlineStatus: Equatable, Sendable {
  public let phase: AcpPermissionDeadlinePhase
  public let label: String
  public let accessibilityValue: String
  public let symbolName: String

  public init(
    phase: AcpPermissionDeadlinePhase,
    label: String,
    accessibilityValue: String,
    symbolName: String
  ) {
    self.phase = phase
    self.label = label
    self.accessibilityValue = accessibilityValue
    self.symbolName = symbolName
  }
}

public extension AcpPermissionDecisionPayload {
  var expiresAtDate: Date? {
    Self.parseExpiresAt(rawBatch.expiresAt)
  }

  func deadlineStatus(
    now: Date,
    lastMessageAt: Date?
  ) -> AcpPermissionDeadlineStatus? {
    guard let expiresAt = expiresAtDate else {
      return nil
    }
    return Self.makeDeadlineStatus(
      expiresAt: expiresAt,
      now: now,
      lastMessageAt: lastMessageAt
    )
  }
}

private extension AcpPermissionDecisionPayload {
  static let expiringWindow: TimeInterval = 30
  static let staleTrafficWindow: TimeInterval = 30
  static let expiringSymbolName = "clock.badge.exclamationmark"

  static func parseExpiresAt(_ value: String?) -> Date? {
    guard let value else {
      return nil
    }
    let withFraction = Date.ISO8601FormatStyle().year().month().day()
      .timeZone(separator: .omitted)
      .time(includingFractionalSeconds: true)
    if let date = try? withFraction.parse(value) {
      return date
    }
    return try? Date.ISO8601FormatStyle().parse(value)
  }

  static func makeDeadlineStatus(
    expiresAt: Date,
    now: Date,
    lastMessageAt: Date?
  ) -> AcpPermissionDeadlineStatus {
    if isTrafficStale(now: now, lastMessageAt: lastMessageAt) {
      return AcpPermissionDeadlineStatus(
        phase: .stale,
        label: "expires soon",
        accessibilityValue: "expires soon",
        symbolName: expiringSymbolName
      )
    }

    let remainingSeconds = Int(ceil(expiresAt.timeIntervalSince(now)))
    if remainingSeconds <= 0 {
      return AcpPermissionDeadlineStatus(
        phase: .expired,
        label: "expired",
        accessibilityValue: "expired",
        symbolName: expiringSymbolName
      )
    }

    let isExpiring = remainingSeconds <= Int(expiringWindow)
    let countdown = countdownString(remainingSeconds)
    let spokenDuration = spokenDurationString(remainingSeconds)
    if isExpiring {
      return AcpPermissionDeadlineStatus(
        phase: .expiring,
        label: "expiring soon — \(countdown)",
        accessibilityValue: "expiring soon, \(spokenDuration) remaining",
        symbolName: expiringSymbolName
      )
    }

    return AcpPermissionDeadlineStatus(
      phase: .pending,
      label: "expires in \(countdown)",
      accessibilityValue: "expires in \(spokenDuration)",
      symbolName: "clock"
    )
  }

  static func isTrafficStale(
    now: Date,
    lastMessageAt: Date?
  ) -> Bool {
    guard let lastMessageAt else {
      return true
    }
    return now.timeIntervalSince(lastMessageAt) > staleTrafficWindow
  }

  static func countdownString(_ remainingSeconds: Int) -> String {
    let minutes = remainingSeconds / 60
    let seconds = remainingSeconds % 60
    return "\(minutes):\(String(format: "%02d", seconds))"
  }

  static func spokenDurationString(_ remainingSeconds: Int) -> String {
    let minutes = remainingSeconds / 60
    let seconds = remainingSeconds % 60
    var parts: [String] = []
    if minutes > 0 {
      let minuteLabel = minutes == 1 ? "minute" : "minutes"
      parts.append("\(minutes) \(minuteLabel)")
    }
    let secondLabel = seconds == 1 ? "second" : "seconds"
    if seconds > 0 || parts.isEmpty {
      parts.append("\(seconds) \(secondLabel)")
    }
    return parts.joined(separator: " ")
  }
}
