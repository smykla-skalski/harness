import Foundation

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
