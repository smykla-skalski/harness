import Foundation

/// Preference keys and defaults for the in-app MCP accessibility registry
/// host. When the host is enabled, `HarnessMonitorMCPAccessibilityService`
/// binds a Unix-domain socket inside the app-group container so the
/// `harness mcp serve` client can connect to it.
public enum HarnessMonitorMCPPreferencesDefaults {
  /// `@AppStorage` key for the master toggle. Bool. Default: `false`.
  public static let registryHostEnabledKey = "harnessMonitorMCPRegistryHostEnabled"

  /// Default value for the master toggle. The host is off until the user
  /// explicitly opts in.
  public static let registryHostEnabledDefault = false

  /// App-group identifier shared with the harness CLI MCP client. The
  /// socket lives inside this container so the sandboxed app and the
  /// unsandboxed CLI can both reach it.
  public static let appGroupIdentifier = "Q498EB36N4.io.harnessmonitor"

  /// Filename of the NDJSON accessibility socket inside the app-group
  /// container.
  public static let socketFilename = "harness-monitor-mcp.sock"
}

/// Resolve the absolute path of the accessibility registry socket. Mirrors
/// the CLI-side `default_socket_path` so both ends bind/connect to the
/// same location.
public enum HarnessMonitorMCPSocketPath {
  /// Returns the absolute socket path, or `nil` if the app-group container
  /// cannot be resolved.
  public static func resolved(
    fileManager: FileManager = .default,
    appGroup: String = HarnessMonitorMCPPreferencesDefaults.appGroupIdentifier,
    filename: String = HarnessMonitorMCPPreferencesDefaults.socketFilename
  ) -> URL? {
    guard
      let container = fileManager.containerURL(
        forSecurityApplicationGroupIdentifier: appGroup
      )
    else {
      return nil
    }
    return container.appendingPathComponent(filename, isDirectory: false)
  }
}
