import Darwin
import Foundation

@testable import HarnessMonitorKit

struct LiveDaemonFixture {
  let process: Process
  let connection: HarnessMonitorConnection
  private static let manifestTimeout: TimeInterval = 60
  private static let healthTimeout: TimeInterval = 30

  static func start(
    xdgDataHome: URL,
    daemonDataHome: URL,
    environmentOverrides: [String: String] = [:]
  ) async throws -> Self {
    let manifestURL =
      daemonDataHome
      .appendingPathComponent("harness", isDirectory: true)
      .appendingPathComponent("daemon", isDirectory: true)
      .appendingPathComponent("manifest.json")
    try FileManager.default.createDirectory(
      at: manifestURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    let cargoCommand =
      "scripts/cargo-local.sh run --quiet -- daemon serve --host 127.0.0.1 --port 0"
    process.arguments = [
      "-c",
      "cd \"\(repoRoot().path)\" && \(cargoCommand)",
    ]
    var processEnvironmentOverrides = [
      "XDG_DATA_HOME": xdgDataHome.path,
      "HARNESS_DAEMON_DATA_HOME": daemonDataHome.path,
      "OTEL_EXPORTER_OTLP_ENDPOINT": "",
      "OTEL_EXPORTER_OTLP_HEADERS": "",
      "OTEL_EXPORTER_OTLP_PROTOCOL": "",
      "HARNESS_OTEL_EXPORT": "",
      "HARNESS_OTEL_GRAFANA_URL": "",
      "HARNESS_OTEL_PYROSCOPE_URL": "",
    ]
    for (key, value) in environmentOverrides {
      processEnvironmentOverrides[key] = value
    }
    process.environment = mergedEnvironment(overrides: processEnvironmentOverrides)
    try process.run()
    do {
      let manifest = try waitForDaemonManifest(
        at: manifestURL,
        timeout: Self.manifestTimeout
      )
      let token = try String(contentsOfFile: manifest.tokenPath, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let connection = HarnessMonitorConnection(
        endpoint: manifest.endpoint,
        token: token
      )
      try await waitForDaemonHealth(
        connection: connection,
        timeout: Self.healthTimeout
      )
      return Self(
        process: process,
        connection: connection
      )
    } catch {
      terminateDaemonProcess(process)
      throw error
    }
  }

  func stop() async {
    guard process.isRunning else {
      return
    }

    do {
      let client = HarnessMonitorAPIClient(connection: connection)
      _ = try await client.stopDaemon()
      await client.shutdown()
    } catch {
      process.terminate()
    }

    for _ in 0..<150 where process.isRunning {
      try? await Task.sleep(nanoseconds: 100_000_000)
    }

    if process.isRunning {
      process.terminate()
    }
  }
}

private struct LiveDaemonManifest: Decodable {
  let endpoint: URL
  let tokenPath: String
}

private func waitForDaemonManifest(
  at url: URL,
  timeout: TimeInterval
) throws -> LiveDaemonManifest {
  let deadline = Date().addingTimeInterval(timeout)
  let decoder = JSONDecoder()
  decoder.keyDecodingStrategy = .convertFromSnakeCase

  while Date() < deadline {
    if FileManager.default.fileExists(atPath: url.path) {
      let data = try Data(contentsOf: url)
      if let manifest = try? decoder.decode(LiveDaemonManifest.self, from: data) {
        return manifest
      }
    }
    Thread.sleep(forTimeInterval: 0.1)
  }

  throw URLError(.timedOut)
}

func mergedEnvironment(overrides: [String: String]) -> [String: String] {
  var environment = ProcessInfo.processInfo.environment
  for (key, value) in overrides {
    environment[key] = value
  }
  return environment
}

private func waitForDaemonHealth(
  connection: HarnessMonitorConnection,
  timeout: TimeInterval
) async throws {
  let client = HarnessMonitorAPIClient(connection: connection)
  defer {
    Task {
      await client.shutdown()
    }
  }

  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    do {
      _ = try await client.health()
      return
    } catch {
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  throw URLError(.timedOut)
}

private func terminateDaemonProcess(_ process: Process) {
  guard process.isRunning else {
    return
  }

  process.terminate()
  let deadline = Date().addingTimeInterval(5)
  while process.isRunning && Date() < deadline {
    Thread.sleep(forTimeInterval: 0.1)
  }

  if process.isRunning {
    kill(process.processIdentifier, SIGKILL)
  }
}
