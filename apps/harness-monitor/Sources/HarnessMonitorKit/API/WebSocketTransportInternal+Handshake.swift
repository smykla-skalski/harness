import Foundation

extension WebSocketTransport {
  private struct ClientHandshakeMetadata {
    let name: String
    let version: String
    let bundleIdentifier: String
    let processIdentifier: Int32
    let launchMode: String

    var userAgent: String {
      "HarnessMonitor/\(version) "
        + "(bundle=\(bundleIdentifier); pid=\(processIdentifier); launch=\(launchMode))"
    }

    var logIdentity: String {
      "\(name)/\(version) "
        + "(bundle=\(bundleIdentifier); pid=\(processIdentifier); launch=\(launchMode))"
    }

    var headers: [String: String] {
      [
        "User-Agent": userAgent,
        WebSocketTransport.clientNameHeaderField: name,
        WebSocketTransport.clientVersionHeaderField: version,
        WebSocketTransport.clientBundleIDHeaderField: bundleIdentifier,
        WebSocketTransport.clientPIDHeaderField: String(processIdentifier),
        WebSocketTransport.clientLaunchModeHeaderField: launchMode,
      ]
    }
  }

  private static let clientNameHeaderField = "X-Harness-Client-Name"
  private static let clientVersionHeaderField = "X-Harness-Client-Version"
  private static let clientBundleIDHeaderField = "X-Harness-Client-Bundle-ID"
  private static let clientPIDHeaderField = "X-Harness-Client-PID"
  private static let clientLaunchModeHeaderField = "X-Harness-Client-Launch-Mode"
  private static let defaultClientName = "harness-monitor"
  private static let defaultClientVersion = "0.0.0"
  private static let defaultClientBundleID = "io.harnessmonitor.app"

  func applyHandshakeHeaders(to request: inout URLRequest) {
    connection.applyAuthenticationHeaders(to: &request)
    for (field, value) in currentClientHandshakeMetadata().headers {
      request.setValue(value, forHTTPHeaderField: field)
    }
  }

  nonisolated func currentClientLogIdentity() -> String {
    currentClientHandshakeMetadata().logIdentity
  }

  nonisolated static func makeClientMetadataHeaders(
    bundleIdentifier: String?,
    appVersion: String?,
    processIdentifier: Int32,
    environment: [String: String]
  ) -> [String: String] {
    makeClientHandshakeMetadata(
      bundleIdentifier: bundleIdentifier,
      appVersion: appVersion,
      processIdentifier: processIdentifier,
      environment: environment
    ).headers
  }

  nonisolated static func makeClientLogIdentity(
    bundleIdentifier: String?,
    appVersion: String?,
    processIdentifier: Int32,
    environment: [String: String]
  ) -> String {
    makeClientHandshakeMetadata(
      bundleIdentifier: bundleIdentifier,
      appVersion: appVersion,
      processIdentifier: processIdentifier,
      environment: environment
    ).logIdentity
  }

  nonisolated private static func resolvedClientValue(
    _ value: String?,
    defaultValue: String
  ) -> String {
    guard let value else {
      return defaultValue
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? defaultValue : trimmed
  }

  nonisolated private func currentClientHandshakeMetadata() -> ClientHandshakeMetadata {
    Self.makeClientHandshakeMetadata(
      bundleIdentifier: Bundle.main.bundleIdentifier,
      appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
      processIdentifier: ProcessInfo.processInfo.processIdentifier,
      environment: ProcessInfo.processInfo.environment
    )
  }

  nonisolated private static func makeClientHandshakeMetadata(
    bundleIdentifier: String?,
    appVersion: String?,
    processIdentifier: Int32,
    environment: [String: String]
  ) -> ClientHandshakeMetadata {
    let resolvedBundleIdentifier = resolvedClientValue(
      bundleIdentifier,
      defaultValue: defaultClientBundleID
    )
    let resolvedVersion = resolvedClientValue(
      appVersion,
      defaultValue: defaultClientVersion
    )
    let launchMode = HarnessMonitorLaunchMode(environment: environment).rawValue

    return ClientHandshakeMetadata(
      name: defaultClientName,
      version: resolvedVersion,
      bundleIdentifier: resolvedBundleIdentifier,
      processIdentifier: processIdentifier,
      launchMode: launchMode
    )
  }

  nonisolated func wsEndpoint() -> URL {
    guard
      var components = URLComponents(
        url: connection.endpoint,
        resolvingAgainstBaseURL: false
      )
    else {
      return connection.endpoint
    }
    components.scheme = connection.endpoint.scheme == "https" ? "wss" : "ws"
    components.path = "/v1/ws"
    return components.url ?? connection.endpoint
  }
}
