import Foundation

public protocol DaemonControlling: Sendable {
  func bootstrapClient() async throws -> any MonitorClientProtocol
  func startDaemonClient() async throws -> any MonitorClientProtocol
  func daemonStatus() async throws -> DaemonStatusReport
  func installLaunchAgent() async throws -> String
  func removeLaunchAgent() async throws -> String
}

public enum DaemonControlError: Error, LocalizedError, Equatable {
  case harnessBinaryNotFound
  case manifestMissing
  case manifestUnreadable
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
    case .daemonDidNotStart:
      "The harness daemon did not become healthy before the timeout."
    case .commandFailed(let message):
      message
    }
  }
}

public struct DaemonController: DaemonControlling {
  private let environment: MonitorEnvironment
  private let sessionFactory: @Sendable (MonitorConnection) -> any MonitorClientProtocol

  public init(
    environment: MonitorEnvironment = .current,
    sessionFactory: @escaping @Sendable (MonitorConnection) -> any MonitorClientProtocol = {
      MonitorAPIClient(connection: $0)
    }
  ) {
    self.environment = environment
    self.sessionFactory = sessionFactory
  }

  public func bootstrapClient() async throws -> any MonitorClientProtocol {
    let manifest = try loadManifest()
    let token = try loadToken(path: manifest.tokenPath)
    let client = sessionFactory(
      MonitorConnection(
        endpoint: try endpointURL(from: manifest.endpoint),
        token: token
      )
    )
    _ = try await client.health()
    return client
  }

  public func startDaemonClient() async throws -> any MonitorClientProtocol {
    let binary = try harnessBinaryURL()
    try startDetachedDaemon(binary: binary)
    return try await waitForHealthyClient()
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

  private func waitForHealthyClient() async throws -> any MonitorClientProtocol {
    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline {
      if let client = try? await bootstrapClient() {
        return client
      }
      try await Task.sleep(for: .milliseconds(250))
    }
    throw DaemonControlError.daemonDidNotStart
  }

  private func loadManifest() throws -> DaemonManifest {
    let manifestURL = MonitorPaths.manifestURL(using: environment)
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
      throw MonitorAPIError.invalidEndpoint(value)
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

  private func startDetachedDaemon(binary: URL) throws {
    let process = Process()
    process.executableURL = binary
    process.arguments = ["daemon", "serve", "--host", "127.0.0.1", "--port", "0"]
    let nullSink = try FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
    process.standardOutput = nullSink
    process.standardError = nullSink
    try process.run()
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
