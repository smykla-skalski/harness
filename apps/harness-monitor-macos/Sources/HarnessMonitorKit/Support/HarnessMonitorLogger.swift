import Foundation
import os

public enum HarnessMonitorLogger {
  public static let defaultDaemonLogLevel = "trace"
  public static let defaultDaemonFilter = "harness=trace"
  public static let defaultAppLogLevel = OSLogType.debug
  private static let supervisorLogGate = SupervisorLogGate(
    daemonLevel: defaultDaemonLogLevel
  )

  public static let api = Logger(subsystem: "io.harnessmonitor", category: "api")
  public static let websocket = Logger(subsystem: "io.harnessmonitor", category: "websocket")
  public static let store = Logger(subsystem: "io.harnessmonitor", category: "store")
  public static let lifecycle = Logger(subsystem: "io.harnessmonitor", category: "lifecycle")
  public static let sleep = Logger(subsystem: "io.harnessmonitor", category: "sleep")
  public static let thumbnail = Logger(subsystem: "io.harnessmonitor", category: "thumbnail")
  public static let supervisor = Logger(subsystem: "io.harnessmonitor", category: "supervisor")

  public static func syncSupervisorLogLevel(from daemonLevel: String?) {
    supervisorLogGate.sync(daemonLevel: daemonLevel ?? defaultDaemonLogLevel)
  }

  public static func supervisorTrace(_ message: @escaping @autoclosure () -> String) {
    guard shouldLogSupervisor(.trace) else { return }
    supervisor.trace("\(message(), privacy: .public)")
  }

  public static func supervisorDebug(_ message: @escaping @autoclosure () -> String) {
    guard shouldLogSupervisor(.debug) else { return }
    supervisor.debug("\(message(), privacy: .public)")
  }

  public static func supervisorInfo(_ message: @escaping @autoclosure () -> String) {
    guard shouldLogSupervisor(.info) else { return }
    supervisor.info("\(message(), privacy: .public)")
  }

  public static func supervisorWarning(_ message: @escaping @autoclosure () -> String) {
    guard shouldLogSupervisor(.warning) else { return }
    supervisor.warning("\(message(), privacy: .public)")
  }

  public static func supervisorError(_ message: @escaping @autoclosure () -> String) {
    guard shouldLogSupervisor(.error) else { return }
    supervisor.error("\(message(), privacy: .public)")
  }

  private static func shouldLogSupervisor(_ severity: SupervisorLogSeverity) -> Bool {
    supervisorLogGate.allows(severity)
  }
}

private final class SupervisorLogGate: @unchecked Sendable {
  private let lock = NSLock()
  private var threshold: SupervisorLogThreshold

  init(daemonLevel: String) {
    threshold = SupervisorLogThreshold(daemonLevel: daemonLevel)
  }

  func sync(daemonLevel: String) {
    let nextThreshold = SupervisorLogThreshold(daemonLevel: daemonLevel)
    lock.withLock {
      threshold = nextThreshold
    }
  }

  func allows(_ severity: SupervisorLogSeverity) -> Bool {
    lock.withLock {
      threshold.allows(severity)
    }
  }
}

private struct SupervisorLogThreshold {
  private let minimumSeverity: SupervisorLogSeverity

  init(daemonLevel: String) {
    switch daemonLevel.lowercased() {
    case "trace":
      minimumSeverity = .trace
    case "debug":
      minimumSeverity = .debug
    case "info":
      minimumSeverity = .info
    case "warn", "warning":
      minimumSeverity = .warning
    case "error":
      minimumSeverity = .error
    default:
      minimumSeverity = .trace
    }
  }

  func allows(_ severity: SupervisorLogSeverity) -> Bool {
    severity.rawValue >= minimumSeverity.rawValue
  }
}

private enum SupervisorLogSeverity: Int {
  case trace
  case debug
  case info
  case warning
  case error
}
