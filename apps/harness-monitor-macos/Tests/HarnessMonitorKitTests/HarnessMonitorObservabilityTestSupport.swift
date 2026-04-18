import Darwin
import Foundation
import GRPC
import NIO
import OpenTelemetryProtocolExporterCommon
import OpenTelemetryProtocolExporterGrpc

@testable import HarnessMonitorKit

func makeTestEnvironment(
  collector: GRPCCollectorServer
) throws -> (URL, HarnessMonitorEnvironment) {
  let temporaryHome = try temporaryDirectory()
  try writeSharedConfig(
    homeDirectory: temporaryHome,
    grpcEndpoint: collector.endpoint.absoluteString
  )
  let environment = HarnessMonitorEnvironment(
    values: [
      "XDG_DATA_HOME": temporaryHome.path,
      "OTEL_EXPORTER_OTLP_PROTOCOL": "grpc",
    ],
    homeDirectory: temporaryHome
  )
  return (temporaryHome, environment)
}

func writeSharedConfig(homeDirectory: URL, grpcEndpoint: String) throws {
  let configURL =
    homeDirectory
    .appendingPathComponent("harness", isDirectory: true)
    .appendingPathComponent("observability", isDirectory: true)
    .appendingPathComponent("config.json")
  try FileManager.default.createDirectory(
    at: configURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  let json = """
    {
      "enabled": true,
      "grpc_endpoint": "\(grpcEndpoint)",
      "http_endpoint": "http://127.0.0.1:4318",
      "grafana_url": "http://127.0.0.1:3000",
      "monitor_smoke_enabled": false,
      "headers": {}
    }
    """
  try json.write(to: configURL, atomically: true, encoding: .utf8)
}

func temporaryDirectory() throws -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}

struct LiveDaemonFixture {
  let process: Process
  let connection: HarnessMonitorConnection

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

    let manifest = try waitForDaemonManifest(at: manifestURL)
    let token = try String(contentsOfFile: manifest.tokenPath, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let connection = HarnessMonitorConnection(
      endpoint: manifest.endpoint,
      token: token
    )
    try await waitForDaemonHealth(connection: connection)
    return Self(
      process: process,
      connection: connection
    )
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

private func waitForDaemonManifest(at url: URL) throws -> LiveDaemonManifest {
  let deadline = Date().addingTimeInterval(15)
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

private func mergedEnvironment(overrides: [String: String]) -> [String: String] {
  var environment = ProcessInfo.processInfo.environment
  for (key, value) in overrides {
    environment[key] = value
  }
  return environment
}

func liveCollectorEnvironmentOverrides(
  from config: HarnessMonitorObservabilityConfig
) -> [String: String] {
  var overrides: [String: String] = [:]

  switch config.transport {
  case .grpc:
    overrides["OTEL_EXPORTER_OTLP_PROTOCOL"] = "grpc"
    overrides["OTEL_EXPORTER_OTLP_ENDPOINT"] = config.grpcEndpoint?.absoluteString ?? ""
  case .httpProtobuf:
    overrides["OTEL_EXPORTER_OTLP_PROTOCOL"] = "http/protobuf"
    overrides["OTEL_EXPORTER_OTLP_ENDPOINT"] =
      httpBaseEndpoint(from: config.httpSignalEndpoints?.traces)?.absoluteString ?? ""
  }

  if config.headers.isEmpty == false {
    overrides["OTEL_EXPORTER_OTLP_HEADERS"] = config.headers
      .sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value)" }
      .joined(separator: ",")
  }

  return overrides
}

private func httpBaseEndpoint(from endpoint: URL?) -> URL? {
  guard let endpoint else {
    return nil
  }

  let lastComponent = endpoint.lastPathComponent.lowercased()
  if ["traces", "metrics", "logs"].contains(lastComponent) {
    return endpoint.deletingLastPathComponent()
  }
  return endpoint
}

private func waitForDaemonHealth(connection: HarnessMonitorConnection) async throws {
  let client = HarnessMonitorAPIClient(connection: connection)
  defer {
    Task {
      await client.shutdown()
    }
  }

  let deadline = Date().addingTimeInterval(15)
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

func repoRoot(filePath: StaticString = #filePath) -> URL {
  URL(fileURLWithPath: "\(filePath)")
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
}

func smokeEnvironment(filePath: StaticString = #filePath) throws -> HarnessMonitorEnvironment {
  guard let smokeDataHome = try smokeDataHomeURL(filePath: filePath) else {
    return .current
  }

  return HarnessMonitorEnvironment(
    values: ["XDG_DATA_HOME": smokeDataHome.path],
    homeDirectory: FileManager.default.homeDirectoryForCurrentUser
  )
}

private func smokeDataHomeURL(filePath: StaticString = #filePath) throws -> URL? {
  let testFileURL = URL(fileURLWithPath: "\(filePath)")

  let repoRoot =
    testFileURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let markerURL =
    repoRoot
    .appendingPathComponent("tmp", isDirectory: true)
    .appendingPathComponent("observability", isDirectory: true)
    .appendingPathComponent("monitor-smoke-data-home.txt")
  guard FileManager.default.fileExists(atPath: markerURL.path) else {
    return nil
  }

  let rawDataHome = try String(contentsOf: markerURL, encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines)
  guard rawDataHome.isEmpty == false else {
    return nil
  }
  return URL(fileURLWithPath: rawDataHome, isDirectory: true)
}
