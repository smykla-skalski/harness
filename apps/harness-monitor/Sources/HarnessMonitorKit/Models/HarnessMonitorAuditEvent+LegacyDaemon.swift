import Foundation

extension HarnessMonitorAuditEvent {
  private static let legacyDaemonIDPrefix = "legacy-daemon:"

  public static func legacyDaemonLog(_ event: DaemonAuditEvent) -> Self {
    let recordedAt = parseDate(event.recordedAt) ?? .distantPast
    return Self(
      id: "\(legacyDaemonIDPrefix)\(stableLegacyDaemonID(event))",
      recordedAt: recordedAt,
      source: "daemon",
      category: "legacyDaemonLog",
      kind: "daemon.log.\(event.level)",
      severity: daemonSeverity(event.level),
      outcome: daemonOutcome(event.level),
      title: "Daemon \(event.level.uppercased())",
      summary: event.message,
      legacyMessage: event.message
    )
  }

  private static func stableLegacyDaemonID(_ event: DaemonAuditEvent) -> String {
    [event.recordedAt, event.level, event.message]
      .joined(separator: "|")
      .replacingOccurrences(of: " ", with: "-")
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: ":", with: "-")
      .prefix(160)
      .description
  }

  private static func daemonSeverity(_ level: String) -> String {
    switch level.lowercased() {
    case "error":
      "error"
    case "warn", "warning":
      "warning"
    case "debug", "trace":
      "debug"
    default:
      "info"
    }
  }

  private static func daemonOutcome(_ level: String) -> String {
    switch level.lowercased() {
    case "error":
      "failure"
    case "warn", "warning":
      "warning"
    default:
      "recorded"
    }
  }
}
