import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Harness Monitor observability config")
struct HarnessMonitorObservabilityConfigTests {
  @Test("Shared config defaults to gRPC export")
  func sharedConfigDefaultsToGrpcExport() throws {
    let tempDirectory = try temporaryDirectory()

    let configURL =
      tempDirectory
      .appendingPathComponent("harness", isDirectory: true)
      .appendingPathComponent("observability", isDirectory: true)
      .appendingPathComponent("config.json")
    try FileManager.default.createDirectory(
      at: configURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try writeSharedConfig(
      to: configURL,
      body: """
        {
          "enabled": true,
          "grpc_endpoint": "http://127.0.0.1:4317",
          "http_endpoint": "http://127.0.0.1:4318",
          "grafana_url": "http://127.0.0.1:3000",
          "pyroscope_url": "http://127.0.0.1:4040",
          "headers": {
            "x-harness-env": "local"
          }
        }
        """
    )
    let environment = HarnessMonitorEnvironment(
      values: ["XDG_DATA_HOME": tempDirectory.path],
      homeDirectory: tempDirectory
    )

    let resolvedConfig = try HarnessMonitorObservabilityConfig.resolve(using: environment)
    let config = try #require(resolvedConfig)

    #expect(config.source == .sharedFile)
    #expect(config.transport == .grpc)
    #expect(config.grpcEndpoint?.absoluteString == "http://127.0.0.1:4317")
    #expect(config.httpSignalEndpoints == nil)
    #expect(config.pyroscopeURL?.absoluteString == "http://127.0.0.1:4040")
    #expect(config.headers["x-harness-env"] == "local")
  }

  @Test("Explicit environment selects HTTP signal endpoints")
  func explicitEnvironmentSelectsHTTPSignalEndpoints() throws {
    let environment = HarnessMonitorEnvironment(
      values: [
        "OTEL_EXPORTER_OTLP_ENDPOINT": "http://127.0.0.1:4318",
        "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
        "OTEL_EXPORTER_OTLP_HEADERS": "x-harness-env=local,x-tenant=test",
        "HARNESS_OTEL_PYROSCOPE_URL": "http://127.0.0.1:4404",
      ],
      homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
    )

    let resolvedConfig = try HarnessMonitorObservabilityConfig.resolve(using: environment)
    let config = try #require(resolvedConfig)

    #expect(config.source == .environment)
    #expect(config.transport == .httpProtobuf)
    #expect(config.grpcEndpoint == nil)
    #expect(
      config.httpSignalEndpoints?.traces.absoluteString
        == "http://127.0.0.1:4318/v1/traces"
    )
    #expect(
      config.httpSignalEndpoints?.metrics.absoluteString
        == "http://127.0.0.1:4318/v1/metrics"
    )
    #expect(
      config.httpSignalEndpoints?.logs.absoluteString
        == "http://127.0.0.1:4318/v1/logs"
    )
    #expect(config.pyroscopeURL?.absoluteString == "http://127.0.0.1:4404")
    #expect(config.headers["x-harness-env"] == "local")
    #expect(config.headers["x-tenant"] == "test")
  }

  @Test("Explicit environment keeps gRPC endpoint precedence over shared config")
  func explicitEnvironmentKeepsGrpcPrecedenceOverSharedConfig() throws {
    let tempDirectory = try temporaryDirectory()

    let configURL =
      tempDirectory
      .appendingPathComponent("harness", isDirectory: true)
      .appendingPathComponent("observability", isDirectory: true)
      .appendingPathComponent("config.json")
    try FileManager.default.createDirectory(
      at: configURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try writeSharedConfig(
      to: configURL,
      body: """
        {
          "enabled": true,
          "grpc_endpoint": "http://127.0.0.1:4317",
          "http_endpoint": "http://127.0.0.1:4318",
          "headers": {}
        }
        """
    )
    let environment = HarnessMonitorEnvironment(
      values: [
        "XDG_DATA_HOME": tempDirectory.path,
        "OTEL_EXPORTER_OTLP_ENDPOINT": "http://10.0.0.9:14317",
      ],
      homeDirectory: tempDirectory
    )

    let resolvedConfig = try HarnessMonitorObservabilityConfig.resolve(using: environment)
    let config = try #require(resolvedConfig)

    #expect(config.source == .environment)
    #expect(config.transport == .grpc)
    #expect(config.grpcEndpoint?.absoluteString == "http://10.0.0.9:14317")
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func writeSharedConfig(to url: URL, body: String) throws {
    try body.write(to: url, atomically: true, encoding: .utf8)
  }
}
