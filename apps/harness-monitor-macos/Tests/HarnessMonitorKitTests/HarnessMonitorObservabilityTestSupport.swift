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
  try writeSharedConfig(to: configURL, grpcEndpoint: grpcEndpoint)
}

func writeSharedConfig(
  using environment: HarnessMonitorEnvironment,
  grpcEndpoint: String
) throws {
  try writeSharedConfig(
    to: HarnessMonitorPaths.sharedObservabilityConfigURL(using: environment),
    grpcEndpoint: grpcEndpoint
  )
}

private func writeSharedConfig(to configURL: URL, grpcEndpoint: String) throws {
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

func waitForAllSignalExports(
  collector: GRPCCollectorServer,
  environment: HarnessMonitorEnvironment,
  timeout: Duration = .seconds(5)
) async throws {
  do {
    try await waitForTraceExport(timeout: timeout) {
      collector.traceCollector.hasReceivedSpans
        && collector.logCollector.hasReceivedLogs
        && collector.metricCollector.hasReceivedMetrics
    }
  } catch {
    print(deferredExportDebugSummary(collector: collector, environment: environment))
    throw error
  }
}

private let localTempoSearchURL = URL(string: "http://127.0.0.1:3200/api/search")!

private struct TempoSearchResponse: Decodable {
  let traces: [TempoMatchedTrace]
}

private struct TempoMatchedTrace: Decodable {}

func localTempoSearchContainsSpan(
  serviceName: String,
  spanName: String,
  start: Int,
  end: Int
) async throws -> Bool {
  var components = URLComponents(url: localTempoSearchURL, resolvingAgainstBaseURL: false)
  components?.queryItems = [
    URLQueryItem(
      name: "q",
      value: "{resource.service.name=\"\(serviceName)\" && name=\"\(spanName)\"}"
    ),
    URLQueryItem(name: "start", value: String(start)),
    URLQueryItem(name: "end", value: String(end)),
  ]
  guard let requestURL = components?.url else {
    throw URLError(.badURL)
  }
  let (data, response) = try await URLSession.shared.data(from: requestURL)
  guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
    throw URLError(.badServerResponse)
  }
  return try JSONDecoder().decode(TempoSearchResponse.self, from: data).traces.isEmpty == false
}

func waitForLocalTempoSpan(
  serviceName: String,
  spanName: String,
  start: Int,
  timeout: Duration = .seconds(15),
  pollingInterval: Duration = .milliseconds(250)
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now + timeout

  while clock.now < deadline {
    if try await localTempoSearchContainsSpan(
      serviceName: serviceName,
      spanName: spanName,
      start: start,
      end: Int(Date().timeIntervalSince1970) + 1
    ) {
      return
    }

    try await Task.sleep(for: pollingInterval)
  }

  throw URLError(.timedOut)
}

private func deferredExportDebugSummary(
  collector: GRPCCollectorServer,
  environment: HarnessMonitorEnvironment
) -> String {
  let bufferRoot =
    HarnessMonitorPaths.harnessRoot(using: environment)
    .appendingPathComponent("observability", isDirectory: true)
    .appendingPathComponent("otlp-buffer", isDirectory: true)
  let traceFiles = bufferedExportFileNames(signal: "traces", bufferRoot: bufferRoot)
  let logFiles = bufferedExportFileNames(signal: "logs", bufferRoot: bufferRoot)
  let metricFiles = bufferedExportFileNames(signal: "metrics", bufferRoot: bufferRoot)

  return [
    "deferred export debug:",
    "traces=\(collector.traceCollector.exportedSpans.count)",
    "logs=\(collector.logCollector.receivedLogs.count)",
    "metrics=\(collector.metricCollector.receivedMetrics.count)",
    "traceFiles=\(traceFiles)",
    "logFiles=\(logFiles)",
    "metricFiles=\(metricFiles)",
  ].joined(separator: " ")
}

private func bufferedExportFileNames(signal: String, bufferRoot: URL) -> [String] {
  let signalRoot = bufferRoot.appendingPathComponent(signal, isDirectory: true)
  let entries = try? FileManager.default.contentsOfDirectory(
    at: signalRoot,
    includingPropertiesForKeys: nil
  )
  return (entries ?? []).map(\.lastPathComponent)
}
