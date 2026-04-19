import Foundation
import XCTest

@MainActor
final class HarnessMonitorAgentsE2ELiveHarness {
  private enum EnvironmentKey {
    static let stateRoot = "HARNESS_MONITOR_E2E_STATE_ROOT"
    static let dataHome = "HARNESS_MONITOR_E2E_DATA_HOME"
    static let daemonLog = "HARNESS_MONITOR_E2E_DAEMON_LOG"
    static let bridgeLog = "HARNESS_MONITOR_E2E_BRIDGE_LOG"
    static let terminalSessionID = "HARNESS_MONITOR_E2E_TERMINAL_SESSION_ID"
    static let codexSessionID = "HARNESS_MONITOR_E2E_CODEX_SESSION_ID"
  }

  let purpose: String
  let stateRootURL: URL
  let dataHomeURL: URL
  let sessionID: String
  let daemonLogPath: String
  let bridgeLogPath: String

  private init(
    purpose: String,
    stateRootURL: URL,
    dataHomeURL: URL,
    sessionID: String,
    daemonLogPath: String,
    bridgeLogPath: String
  ) {
    self.purpose = purpose
    self.stateRootURL = stateRootURL
    self.dataHomeURL = dataHomeURL
    self.sessionID = sessionID
    self.daemonLogPath = daemonLogPath
    self.bridgeLogPath = bridgeLogPath
  }

  static func setUp(
    for _: XCTestCase,
    purpose: String
  ) throws -> HarnessMonitorAgentsE2ELiveHarness {
    let environment = ProcessInfo.processInfo.environment
    let stateRoot = try requiredEnvironmentValue(EnvironmentKey.stateRoot, from: environment)
    let dataHome = try requiredEnvironmentValue(EnvironmentKey.dataHome, from: environment)
    let daemonLog = try requiredEnvironmentValue(EnvironmentKey.daemonLog, from: environment)
    let bridgeLog = try requiredEnvironmentValue(EnvironmentKey.bridgeLog, from: environment)
    let sessionIDKey =
      switch purpose {
      case "terminal":
        EnvironmentKey.terminalSessionID
      case "codex":
        EnvironmentKey.codexSessionID
      default:
        throw failure("Unknown Agents e2e purpose: \(purpose)")
      }
    let sessionID = try requiredEnvironmentValue(sessionIDKey, from: environment)

    return HarnessMonitorAgentsE2ELiveHarness(
      purpose: purpose,
      stateRootURL: URL(fileURLWithPath: stateRoot, isDirectory: true),
      dataHomeURL: URL(fileURLWithPath: dataHome, isDirectory: true),
      sessionID: sessionID,
      daemonLogPath: daemonLog,
      bridgeLogPath: bridgeLog
    )
  }

  var appLaunchEnvironment: [String: String] {
    [
      "HARNESS_DAEMON_DATA_HOME": dataHomeURL.path,
      "HARNESS_MONITOR_EXTERNAL_DAEMON": "1",
      "HARNESS_MONITOR_LAUNCH_MODE": "live",
      "HARNESS_MONITOR_RESET_BACKGROUND_RECENTS": "1",
      "HARNESS_MONITOR_UI_MAIN_WINDOW_HEIGHT": "720",
      "HARNESS_MONITOR_UI_MAIN_WINDOW_WIDTH": "1120",
      "HARNESS_MONITOR_UI_TESTS": "1",
    ]
  }

  func diagnosticsSummary() -> String {
    [
      "purpose=\(purpose)",
      "stateRoot=\(stateRootURL.path)",
      "dataHome=\(dataHomeURL.path)",
      "sessionID=\(sessionID)",
      "daemonLog=\(daemonLogPath)",
      "bridgeLog=\(bridgeLogPath)",
    ].joined(separator: "\n")
  }

  private static func requiredEnvironmentValue(
    _ key: String,
    from environment: [String: String]
  ) throws -> String {
    guard
      let rawValue = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
      rawValue.isEmpty == false
    else {
      throw failure("Missing explicit Agents e2e environment variable: \(key)")
    }
    return rawValue
  }

  private static func failure(_ message: String) -> NSError {
    NSError(
      domain: "HarnessMonitorAgentsE2E",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: message]
    )
  }
}
