import Foundation

public protocol DaemonControlling: Sendable {
  func bootstrapClient() async throws -> any HarnessMonitorClientProtocol
  func startDaemonClient() async throws -> any HarnessMonitorClientProtocol
  func stopDaemon() async throws -> String
  func daemonStatus() async throws -> DaemonStatusReport
  func installLaunchAgent() async throws -> String
  func removeLaunchAgent() async throws -> String
}

public enum DaemonControlError: Error, LocalizedError, Equatable {
  case harnessBinaryNotFound
  case manifestMissing
  case manifestUnreadable
  case daemonOffline
  case daemonDidNotStart
  case commandFailed(String)

  public var errorDescription: String? {
    switch self {
    case .harnessBinaryNotFound:
      "Unable to locate the harness binary. Set HARNESS_BINARY or install harness first."
    case .manifestMissing:
      "The harness daemon manifest is missing."
    case .manifestUnreadable:
      "The harness daemon manifest could not be read."
    case .daemonOffline:
      "The harness daemon is offline. Start the daemon to load live sessions."
    case .daemonDidNotStart:
      "The harness daemon did not become healthy before the timeout."
    case .commandFailed(let message):
      message
    }
  }
}

public enum TransportPreference: Sendable {
  case auto
  case webSocket
  case http
}

public struct DaemonController: DaemonControlling {
  private let environment: HarnessMonitorEnvironment
  private let sessionFactory:
    @Sendable (HarnessMonitorConnection) -> any HarnessMonitorClientProtocol
  private let transportPreference: TransportPreference

  public init(
    environment: HarnessMonitorEnvironment = .current,
    transportPreference: TransportPreference = .auto,
    sessionFactory:
      @escaping @Sendable (HarnessMonitorConnection) -> any HarnessMonitorClientProtocol = {
        HarnessMonitorAPIClient(connection: $0)
      }
  ) {
    self.environment = environment
    self.transportPreference = transportPreference
    self.sessionFactory = sessionFactory
  }

  public func bootstrapClient() async throws -> any HarnessMonitorClientProtocol {
    HarnessMonitorLogger.lifecycle.info("Bootstrapping daemon client")
    let manifest = try loadManifest()
    let token = try loadToken(path: manifest.tokenPath)
    let connection = HarnessMonitorConnection(
      endpoint: try endpointURL(from: manifest.endpoint),
      token: token
    )

    if transportPreference != .http {
      if let wsClient = try? await bootstrapWebSocket(connection: connection) {
        return wsClient
      }
      if transportPreference == .webSocket {
        throw DaemonControlError.commandFailed("WebSocket connection failed")
      }
    }

    let client = sessionFactory(connection)
    _ = try await client.health()
    return client
  }

  private func bootstrapWebSocket(
    connection: HarnessMonitorConnection
  ) async throws -> WebSocketTransport {
    let transport = WebSocketTransport(connection: connection)
    try await transport.connect()
    _ = try await transport.health()
    return transport
  }

  public func startDaemonClient() async throws -> any HarnessMonitorClientProtocol {
    let binary = try harnessBinaryURL()
    try startDetachedDaemon(binary: binary)
    return try await waitForHealthyClient()
  }

  public func stopDaemon() async throws -> String {
    let client = try await bootstrapClient()
    let response = try await client.stopDaemon()
    return response.status
  }

  public func daemonStatus() async throws -> DaemonStatusReport {
    let binary = try harnessBinaryURL()
    let result = try await run(executable: binary, arguments: ["daemon", "status"])
    guard result.exitCode == 0 else {
      throw DaemonControlError.commandFailed(result.stderr.nonEmpty ?? result.stdout)
    }
    return try makeDecoder().decode(DaemonStatusReport.self, from: Data(result.stdout.utf8))
  }

  public func installLaunchAgent() async throws -> String {
    let binary = try harnessBinaryURL()
    let result = try await run(executable: binary, arguments: ["daemon", "install-launch-agent"])
    guard result.exitCode == 0 else {
      throw DaemonControlError.commandFailed(result.stderr.nonEmpty ?? result.stdout)
    }
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public func removeLaunchAgent() async throws -> String {
    let binary = try harnessBinaryURL()
    let result = try await run(executable: binary, arguments: ["daemon", "remove-launch-agent"])
    guard result.exitCode == 0 else {
      throw DaemonControlError.commandFailed(result.stderr.nonEmpty ?? result.stdout)
    }
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func waitForHealthyClient() async throws -> any HarnessMonitorClientProtocol {
    let deadline = Date.now.addingTimeInterval(8)
    while Date.now < deadline {
      if let client = try? await bootstrapClient() {
        return client
      }
      try await Task.sleep(for: .milliseconds(250))
    }
    throw DaemonControlError.daemonDidNotStart
  }

  private func loadManifest() throws -> DaemonManifest {
    let manifestURL = HarnessMonitorPaths.manifestURL(using: environment)
    guard FileManager.default.fileExists(atPath: manifestURL.path) else {
      throw DaemonControlError.manifestMissing
    }

    guard let data = FileManager.default.contents(atPath: manifestURL.path) else {
      throw DaemonControlError.manifestUnreadable
    }

    return try makeDecoder().decode(DaemonManifest.self, from: data)
  }

  private func loadToken(path: String) throws -> String {
    let tokenURL = URL(fileURLWithPath: path)
    return try String(contentsOf: tokenURL, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func endpointURL(from value: String) throws -> URL {
    guard let url = URL(string: value) else {
      throw HarnessMonitorAPIError.invalidEndpoint(value)
    }
    return url
  }

  private func harnessBinaryURL() throws -> URL {
    if let explicit = environment.values["HARNESS_BINARY"], !explicit.isEmpty {
      let url = URL(fileURLWithPath: explicit)
      if FileManager.default.isExecutableFile(atPath: url.path) {
        return url
      }
    }

    let candidates = [
      environment.homeDirectory.appendingPathComponent(".local/bin/harness"),
      URL(fileURLWithPath: "/opt/homebrew/bin/harness"),
      URL(fileURLWithPath: "/usr/local/bin/harness"),
    ]

    let match = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    if let match {
      return match
    }

    throw DaemonControlError.harnessBinaryNotFound
  }

  @discardableResult
  private func startDetachedDaemon(binary: URL) throws -> Process {
    let process = Process()
    process.executableURL = binary
    process.arguments = ["daemon", "serve", "--host", "127.0.0.1", "--port", "0"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return process
  }

  private func run(executable: URL, arguments: [String]) async throws -> CommandResult {
    try await Task.detached(priority: .userInitiated) {
      let process = Process()
      process.executableURL = executable
      process.arguments = arguments

      let stdout = Pipe()
      let stderr = Pipe()
      process.standardOutput = stdout
      process.standardError = stderr

      try process.run()
      process.waitUntilExit()

      let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
      let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()

      return CommandResult(
        exitCode: process.terminationStatus,
        stdout: String(data: stdoutData, encoding: .utf8) ?? "",
        stderr: String(data: stderrData, encoding: .utf8) ?? ""
      )
    }.value
  }

  private func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }
}

private struct CommandResult: Sendable {
  let exitCode: Int32
  let stdout: String
  let stderr: String
}

extension String {
  fileprivate var nonEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
