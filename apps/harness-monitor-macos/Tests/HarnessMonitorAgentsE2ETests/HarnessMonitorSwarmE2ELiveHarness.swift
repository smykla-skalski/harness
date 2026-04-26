import Foundation
import XCTest

@MainActor
final class HarnessMonitorSwarmE2ELiveHarness {
  private enum EnvironmentKey {
    static let enableSwarmE2E = "HARNESS_MONITOR_ENABLE_SWARM_E2E"
    static let stateRoot = "HARNESS_MONITOR_SWARM_E2E_STATE_ROOT"
    static let dataHome = "HARNESS_MONITOR_SWARM_E2E_DATA_HOME"
    static let daemonLog = "HARNESS_MONITOR_SWARM_E2E_DAEMON_LOG"
    static let sessionID = "HARNESS_MONITOR_SWARM_E2E_SESSION_ID"
    static let taskID = "HARNESS_MONITOR_SWARM_E2E_TASK_ID"
    static let reviewerAgentID = "HARNESS_MONITOR_SWARM_E2E_REVIEWER_AGENT_ID"
  }

  let stateRootURL: URL
  let dataHomeURL: URL
  let daemonLogPath: String
  let sessionID: String
  let taskID: String
  let reviewerAgentID: String

  private init(
    stateRootURL: URL,
    dataHomeURL: URL,
    daemonLogPath: String,
    sessionID: String,
    taskID: String,
    reviewerAgentID: String
  ) {
    self.stateRootURL = stateRootURL
    self.dataHomeURL = dataHomeURL
    self.daemonLogPath = daemonLogPath
    self.sessionID = sessionID
    self.taskID = taskID
    self.reviewerAgentID = reviewerAgentID
  }

  /// Skips the current test when the orchestrator script has not exported the
  /// required swarm e2e environment variables. This keeps the default
  /// `xcodebuild test` lane from running the live orchestrator by accident.
  static func setUp(for _: XCTestCase) throws -> HarnessMonitorSwarmE2ELiveHarness {
    let environment = ProcessInfo.processInfo.environment
    guard environment[EnvironmentKey.enableSwarmE2E] == "1" else {
      throw XCTSkip(
        """
        Swarm full-flow e2e is explicit-only. \
        Run apps/harness-monitor-macos/Scripts/test-swarm-full-flow-e2e.sh.
        """
      )
    }
    return HarnessMonitorSwarmE2ELiveHarness(
      stateRootURL: URL(
        fileURLWithPath: try required(EnvironmentKey.stateRoot, from: environment),
        isDirectory: true
      ),
      dataHomeURL: URL(
        fileURLWithPath: try required(EnvironmentKey.dataHome, from: environment),
        isDirectory: true
      ),
      daemonLogPath: try required(EnvironmentKey.daemonLog, from: environment),
      sessionID: try required(EnvironmentKey.sessionID, from: environment),
      taskID: try required(EnvironmentKey.taskID, from: environment),
      reviewerAgentID: try required(EnvironmentKey.reviewerAgentID, from: environment)
    )
  }

  var appLaunchEnvironment: [String: String] {
    [
      "HARNESS_DAEMON_DATA_HOME": dataHomeURL.path,
      "HARNESS_MONITOR_EXTERNAL_DAEMON": "1",
      "HARNESS_MONITOR_LAUNCH_MODE": "live",
      "HARNESS_MONITOR_RESET_BACKGROUND_RECENTS": "1",
      "HARNESS_MONITOR_UI_MAIN_WINDOW_HEIGHT": "820",
      "HARNESS_MONITOR_UI_MAIN_WINDOW_WIDTH": "1280",
      "HARNESS_MONITOR_UI_TESTS": "1",
    ]
  }

  func diagnosticsSummary() -> String {
    var lines = [
      "stateRoot=\(stateRootURL.path)",
      "dataHome=\(dataHomeURL.path)",
      "sessionID=\(sessionID)",
      "taskID=\(taskID)",
      "reviewerAgentID=\(reviewerAgentID)",
      "daemonLog=\(daemonLogPath)",
    ]
    if let tracePath = diagnosticsTraceFileURL(
      for: HarnessMonitorUITestCase.artifactsDirectoryKey
    )?.path {
      lines.append("uiTrace=\(tracePath)")
    }
    return lines.joined(separator: "\n")
  }

  private static func required(
    _ key: String,
    from environment: [String: String]
  ) throws -> String {
    guard
      let rawValue = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
      rawValue.isEmpty == false
    else {
      throw NSError(
        domain: "HarnessMonitorSwarmE2E",
        code: 1,
        userInfo: [
          NSLocalizedDescriptionKey: "Missing explicit swarm e2e environment variable: \(key)"
        ]
      )
    }
    return rawValue
  }
}
