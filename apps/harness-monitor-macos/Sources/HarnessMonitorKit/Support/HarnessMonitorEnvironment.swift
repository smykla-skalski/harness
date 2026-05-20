import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

public struct HarnessMonitorEnvironment: Equatable, Sendable {
  public let values: [String: String]
  public let homeDirectory: URL
  public let bundleURL: URL?

  public init(
    values: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    bundleURL: URL? = Bundle.main.bundleURL
  ) {
    self.values = values
    self.homeDirectory = homeDirectory
    self.bundleURL = bundleURL
  }

  public static var current: Self {
    Self(
      values: currentProcessValues(),
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
      bundleURL: Bundle.main.bundleURL
    )
  }

  public var isXCTestProcess: Bool {
    values["XCTestConfigurationFilePath"] != nil
      || values["XCInjectBundle"] != nil
      || values["XCInjectBundleInto"] != nil
      || values["HARNESS_MONITOR_UI_TESTS"] == "1"
      || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
      || ProcessInfo.processInfo.environment["XCInjectBundle"] != nil
      || ProcessInfo.processInfo.environment["XCInjectBundleInto"] != nil
      || ProcessInfo.processInfo.environment["HARNESS_MONITOR_UI_TESTS"] == "1"
      || ProcessInfo.processInfo.processName == "xctest"
  }

  private static func currentProcessValues() -> [String: String] {
    // `ProcessInfo.processInfo.environment` copies the full env dictionary
    // out of CFCopyEnvironment on every access. Cache the baseline once at
    // first read; the only keys that the app needs to re-read at runtime are
    // in `liveEnvironmentOverrideKeys` and we still pull those via `getenv`
    // below. Without this cache every `HarnessMonitorPaths.*` default-arg
    // invocation pays a full env-dict copy.
    var values = baseProcessEnvironment
    for key in liveEnvironmentOverrideKeys {
      if let value = currentCEnvironmentValue(for: key) {
        values[key] = value
      } else {
        values.removeValue(forKey: key)
      }
    }
    return values
  }

  private static let baseProcessEnvironment: [String: String] = {
    var values = ProcessInfo.processInfo.environment
    for key in liveEnvironmentOverrideKeys {
      values.removeValue(forKey: key)
    }
    return values
  }()

  private static func currentCEnvironmentValue(for key: String) -> String? {
    key.withCString { namePointer in
      guard let valuePointer = getenv(namePointer) else { return nil }
      return String(cString: valuePointer)
    }
  }

  private static let liveEnvironmentOverrideKeys = [
    HarnessMonitorAppGroup.daemonDataHomeEnvironmentKey,
    HarnessMonitorAppGroup.environmentKey,
    HarnessMonitorRuntimeLane.environmentKey,
    HarnessMonitorRuntimeLane.launchAgentLabelEnvKey,
    HarnessMonitorRuntimeLane.codexWSPortEnvironmentKey,
    "HARNESS_MONITOR_EXTERNAL_DAEMON",
    "XDG_DATA_HOME",
    "XCODEBUILD_DERIVED_DATA_PATH",
  ]
}

public enum HarnessMonitorAppGroup {
  public static let identifier = "Q498EB36N4.io.harnessmonitor"
  public static let environmentKey = "HARNESS_APP_GROUP_ID"
  public static let daemonDataHomeEnvironmentKey = "HARNESS_DAEMON_DATA_HOME"
}

public enum HarnessMonitorRuntimeLane {
  public static let environmentKey = "HARNESS_MONITOR_RUNTIME_LANE"
  public static let launchAgentLabelEnvKey = "HARNESS_MONITOR_DAEMON_LAUNCH_AGENT_LABEL"
  public static let codexWSPortEnvironmentKey = "HARNESS_CODEX_WS_PORT"

  static let launchAgentName = "daemon"
  static let launchAgentBaseLabel = "\(HarnessMonitorAppGroup.identifier).\(launchAgentName)"
  static let dataHomeLanesDirectoryName = "runtime-lanes"
  static let codexWSPortBase = 4_600
  static let codexWSPortSpan = 20_000
}
