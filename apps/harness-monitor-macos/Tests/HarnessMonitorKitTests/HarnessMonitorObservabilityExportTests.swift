import Foundation
import GRPC
import NIO
import OpenTelemetryProtocolExporterCommon
import OpenTelemetryProtocolExporterGrpc
import Testing

@testable import HarnessMonitorKit

@Suite("Harness Monitor observability export")
struct HarnessMonitorObservabilityExportTests {
  @Test("HTTP/protobuf shutdown exports traces, logs, and metrics")
  func httpProtobufShutdownExportsAllSignals() async throws {
    OTLPAndTimelineURLProtocol.reset()
    defer {
      HarnessMonitorTelemetry.shared.resetForTests()
      OTLPAndTimelineURLProtocol.reset()
    }

    let temporaryHome = try temporaryDirectory()
    let environment = HarnessMonitorEnvironment(
      values: [
        "HARNESS_OTEL_EXPORT": "1",
        "OTEL_EXPORTER_OTLP_ENDPOINT": "http://127.0.0.1:4318",
        "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
      ],
      homeDirectory: temporaryHome
    )

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OTLPAndTimelineURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let client = HarnessMonitorAPIClient(
      connection: HarnessMonitorConnection(
        endpoint: URL(string: "http://127.0.0.1:9999")!,
        token: "token"
      ),
      session: session
    )

    HarnessMonitorTelemetry.shared.resetForTests()
    HarnessMonitorTelemetry.shared.setHTTPExporterSessionForTests(session)
    HarnessMonitorTelemetry.shared.bootstrap(using: environment)
    let entries = try await client.timeline(sessionID: "observability-export", scope: .summary)
    HarnessMonitorTelemetry.shared.shutdown()

    #expect(entries.count == 1)
    #expect(
      try await OTLPAndTimelineURLProtocol.waitForExportPaths(
        ["/v1/traces", "/v1/logs", "/v1/metrics"],
        timeout: 2
      )
    )
  }
}

@Suite("Harness Monitor observability gRPC export")
struct HarnessMonitorObservabilityGRPCExportTests {
  @Test("gRPC export sends traces, logs, and metrics")
  func grpcExportSendsAllSignals() async throws {
    let collector = try GRPCCollectorServer()
    defer {
      collector.shutdown()
      HarnessMonitorTelemetry.shared.resetForTests()
    }

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

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TimelineURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let client = HarnessMonitorAPIClient(
      connection: HarnessMonitorConnection(
        endpoint: URL(string: "http://127.0.0.1:9999")!,
        token: "token"
      ),
      session: session
    )

    HarnessMonitorTelemetry.shared.resetForTests()
    HarnessMonitorTelemetry.shared.bootstrap(using: environment)
    let entries = try await client.timeline(sessionID: "grpc-export", scope: .summary)
    HarnessMonitorTelemetry.shared.shutdown()

    #expect(entries.count == 1)
    #expect(collector.traceCollector.hasReceivedSpans)
    #expect(collector.logCollector.hasReceivedLogs)
    #expect(collector.metricCollector.hasReceivedMetrics)
    #expect(collector.traceCollector.serviceNames.contains("harness-monitor"))
    #expect(collector.logCollector.serviceNames.contains("harness-monitor"))
    #expect(collector.metricCollector.serviceNames.contains("harness-monitor"))
    #expect(collector.metricCollector.metricNames.contains("harness_monitor_http_requests_total"))
  }
}

@Suite("Harness Monitor observability smoke")
struct HarnessMonitorObservabilitySmokeTests {
  @Test("Collector-configured shutdown flushes signals for the smoke lane")
  func collectorConfiguredShutdownFlushesSignalsForSmoke() async throws {
    defer {
      HarnessMonitorTelemetry.shared.resetForTests()
      TimelineURLProtocol.reset()
    }

    let environment = try smokeEnvironment()
    let resolvedConfig = try HarnessMonitorObservabilityConfig.resolve(using: environment)
    let config = try #require(resolvedConfig)
    guard config.monitorSmokeEnabled else {
      return
    }
    #expect(config.source == .sharedFile)
    #expect(config.transport == .grpc)
    #expect(config.grpcEndpoint?.absoluteString == "http://127.0.0.1:4317")
    #expect(config.monitorSmokeEnabled)

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TimelineURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let client = HarnessMonitorAPIClient(
      connection: HarnessMonitorConnection(
        endpoint: URL(string: "http://127.0.0.1:9999")!,
        token: "token"
      ),
      session: session
    )

    HarnessMonitorTelemetry.shared.resetForTests()
    HarnessMonitorTelemetry.shared.bootstrap(using: environment)
    let entries = try await client.timeline(sessionID: "observability-smoke", scope: .summary)
    HarnessMonitorTelemetry.shared.shutdown()

    #expect(entries.count == 1)
  }
}

private final class TimelineURLProtocol: URLProtocol, @unchecked Sendable {
  override static func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "127.0.0.1" && request.url?.port == 9999
  }

  override static func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let requestURL = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }

    guard
      let response = HTTPURLResponse(
        url: requestURL,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }

    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(timelineResponseBody(sessionID: "observability-smoke").utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  static func reset() {}
}

private final class OTLPAndTimelineURLProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var exportPaths = Set<String>()

  override static func canInit(with request: URLRequest) -> Bool {
    guard let url = request.url else {
      return false
    }

    if url.host == "127.0.0.1" && url.port == 4318 {
      return true
    }

    return url.host == "127.0.0.1" && url.port == 9999
  }

  override static func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let requestURL = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }

    if requestURL.port == 4318 {
      _ = Self.lock.withLock {
        Self.exportPaths.insert(requestURL.path)
      }

      guard
        let response = HTTPURLResponse(
          url: requestURL,
          statusCode: 200,
          httpVersion: nil,
          headerFields: ["Content-Type": "application/json"]
        )
      else {
        client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
        return
      }

      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data())
      client?.urlProtocolDidFinishLoading(self)
      return
    }

    guard
      let response = HTTPURLResponse(
        url: requestURL,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "application/json"]
      )
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }

    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(timelineResponseBody(sessionID: "observability-export").utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  static func reset() {
    lock.withLock {
      exportPaths.removeAll()
    }
  }

  static func waitForExportPaths(
    _ expectedPaths: Set<String>,
    timeout: TimeInterval
  ) async throws -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if lock.withLock({ expectedPaths.isSubset(of: exportPaths) }) {
        return true
      }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    return lock.withLock { expectedPaths.isSubset(of: exportPaths) }
  }
}

private func timelineResponseBody(sessionID: String) -> String {
  """
  [
    {
      "entry_id": "entry-1",
      "recorded_at": "2026-04-14T03:00:00Z",
      "kind": "tool_result",
      "session_id": "\(sessionID)",
      "agent_id": null,
      "task_id": null,
      "summary": "Summary entry",
      "payload": {}
    }
  ]
  """
}

private func writeSharedConfig(homeDirectory: URL, grpcEndpoint: String) throws {
  let configURL =
    homeDirectory
    .appendingPathComponent("harness", isDirectory: true)
    .appendingPathComponent("observability", isDirectory: true)
    .appendingPathComponent("config.json")
  try FileManager.default.createDirectory(
    at: configURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try """
    {
      "enabled": true,
      "grpc_endpoint": "\(grpcEndpoint)",
      "http_endpoint": "http://127.0.0.1:4318",
      "grafana_url": "http://127.0.0.1:3000",
      "monitor_smoke_enabled": false,
      "headers": {}
    }
    """.write(to: configURL, atomically: true, encoding: .utf8)
}

private func temporaryDirectory() throws -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}

private func smokeEnvironment(filePath: StaticString = #filePath) throws -> HarnessMonitorEnvironment {
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
  let repoRoot = testFileURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let markerURL = repoRoot
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

private final class GRPCCollectorServer: @unchecked Sendable {
  let traceCollector = FakeTraceCollector()
  let logCollector = FakeLogCollector()
  let metricCollector = FakeMetricCollector()

  private let group = PlatformSupport.makeEventLoopGroup(loopCount: 1)
  private let server: Server

  let endpoint: URL

  init() throws {
    server = try Server.insecure(group: group)
      .withServiceProviders([traceCollector, logCollector, metricCollector])
      .bind(host: "127.0.0.1", port: 0)
      .wait()
    guard let port = server.channel.localAddress?.port else {
      throw URLError(.cannotFindHost)
    }
    guard let endpoint = URL(string: "http://127.0.0.1:\(port)") else {
      throw URLError(.badURL)
    }
    self.endpoint = endpoint
  }

  func shutdown() {
    try? server.close().wait()
    try? group.syncShutdownGracefully()
  }
}

private final class FakeTraceCollector: Opentelemetry_Proto_Collector_Trace_V1_TraceServiceProvider {
  var interceptors:
    Opentelemetry_Proto_Collector_Trace_V1_TraceServiceServerInterceptorFactoryProtocol?
  private(set) var receivedSpans = [Opentelemetry_Proto_Trace_V1_ResourceSpans]()

  var hasReceivedSpans: Bool {
    receivedSpans.isEmpty == false
  }

  var serviceNames: Set<String> {
    Set(
      receivedSpans.flatMap { resourceSpans in
        resourceSpans.resource.attributes.compactMap { attribute in
          guard attribute.key == "service.name" else {
            return nil
          }
          return attribute.value.stringValue
        }
      }
    )
  }

  func export(
    request: Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceRequest,
    context: StatusOnlyCallContext
  ) -> EventLoopFuture<Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceResponse> {
    receivedSpans.append(contentsOf: request.resourceSpans)
    return context.eventLoop.makeSucceededFuture(
      Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceResponse()
    )
  }
}

private final class FakeLogCollector: Opentelemetry_Proto_Collector_Logs_V1_LogsServiceProvider {
  var interceptors:
    Opentelemetry_Proto_Collector_Logs_V1_LogsServiceServerInterceptorFactoryProtocol?
  private(set) var receivedLogs = [Opentelemetry_Proto_Logs_V1_ResourceLogs]()

  var hasReceivedLogs: Bool {
    receivedLogs.isEmpty == false
  }

  var serviceNames: Set<String> {
    Set(
      receivedLogs.flatMap { resourceLogs in
        resourceLogs.resource.attributes.compactMap { attribute in
          guard attribute.key == "service.name" else {
            return nil
          }
          return attribute.value.stringValue
        }
      }
    )
  }

  func export(
    request: Opentelemetry_Proto_Collector_Logs_V1_ExportLogsServiceRequest,
    context: StatusOnlyCallContext
  ) -> EventLoopFuture<Opentelemetry_Proto_Collector_Logs_V1_ExportLogsServiceResponse> {
    receivedLogs.append(contentsOf: request.resourceLogs)
    return context.eventLoop.makeSucceededFuture(
      Opentelemetry_Proto_Collector_Logs_V1_ExportLogsServiceResponse()
    )
  }
}

private final class FakeMetricCollector:
  Opentelemetry_Proto_Collector_Metrics_V1_MetricsServiceProvider
{
  var interceptors:
    Opentelemetry_Proto_Collector_Metrics_V1_MetricsServiceServerInterceptorFactoryProtocol?
  private(set) var receivedMetrics = [Opentelemetry_Proto_Metrics_V1_ResourceMetrics]()

  var hasReceivedMetrics: Bool {
    receivedMetrics.isEmpty == false
  }

  var metricNames: Set<String> {
    Set(
      receivedMetrics.flatMap { resourceMetrics in
        resourceMetrics.scopeMetrics.flatMap { scopeMetrics in
          scopeMetrics.metrics.map(\.name)
        }
      }
    )
  }

  var serviceNames: Set<String> {
    Set(
      receivedMetrics.flatMap { resourceMetrics in
        resourceMetrics.resource.attributes.compactMap { attribute in
          guard attribute.key == "service.name" else {
            return nil
          }
          return attribute.value.stringValue
        }
      }
    )
  }

  func export(
    request: Opentelemetry_Proto_Collector_Metrics_V1_ExportMetricsServiceRequest,
    context: StatusOnlyCallContext
  ) -> EventLoopFuture<Opentelemetry_Proto_Collector_Metrics_V1_ExportMetricsServiceResponse> {
    receivedMetrics.append(contentsOf: request.resourceMetrics)
    return context.eventLoop.makeSucceededFuture(
      Opentelemetry_Proto_Collector_Metrics_V1_ExportMetricsServiceResponse()
    )
  }
}
