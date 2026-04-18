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
    let modelContainer = try HarnessMonitorModelContainer.live(using: environment)
    let cacheService = SessionCacheService(
      modelContainer: modelContainer,
      databaseURL: HarnessMonitorPaths.harnessRoot(using: environment)
        .appendingPathComponent("harness-cache.store")
    )
    let cacheCounts = await cacheService.recordCounts()
    let entries = try await client.timeline(sessionID: "grpc-export", scope: .summary)
    HarnessMonitorTelemetry.shared.shutdown()

    #expect(cacheCounts.sessions == 0)
    #expect(entries.count == 1)
    #expect(collector.traceCollector.hasReceivedSpans)
    #expect(collector.logCollector.hasReceivedLogs)
    #expect(collector.metricCollector.hasReceivedMetrics)
    #expect(collector.traceCollector.serviceNames.contains("harness-monitor"))
    #expect(collector.logCollector.serviceNames.contains("harness-monitor"))
    #expect(collector.metricCollector.serviceNames.contains("harness-monitor"))
    #expect(collector.metricCollector.metricNames.contains("harness_monitor_http_requests_total"))
    #expect(collector.metricCollector.metricNames.contains("harness_monitor_sqlite_operations_total"))
    #expect(collector.metricCollector.metricNames.contains("harness_monitor_sqlite_file_size_bytes"))
  }

  @Test("gRPC export keeps websocket client and daemon server spans on one trace")
  func grpcExportKeepsWebSocketClientAndDaemonServerSpansOnOneTrace() async throws {
    let collector = try GRPCCollectorServer()
    defer {
      collector.shutdown()
      HarnessMonitorTelemetry.shared.resetForTests()
    }

    let temporaryHome = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryHome) }

    let xdgDataHome = temporaryHome.appendingPathComponent("xdg-data", isDirectory: true)
    let daemonDataHome = temporaryHome.appendingPathComponent("daemon-data", isDirectory: true)
    try FileManager.default.createDirectory(at: xdgDataHome, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: daemonDataHome, withIntermediateDirectories: true)

    let environment = HarnessMonitorEnvironment(
      values: [
        "XDG_DATA_HOME": xdgDataHome.path,
        HarnessMonitorAppGroup.daemonDataHomeEnvironmentKey: daemonDataHome.path,
        "OTEL_EXPORTER_OTLP_ENDPOINT": collector.endpoint.absoluteString,
        "OTEL_EXPORTER_OTLP_PROTOCOL": "grpc",
      ],
      homeDirectory: temporaryHome
    )
    let daemon = try await LiveDaemonFixture.start(
      xdgDataHome: xdgDataHome,
      daemonDataHome: daemonDataHome,
      environmentOverrides: [
        "OTEL_EXPORTER_OTLP_ENDPOINT": collector.endpoint.absoluteString,
        "OTEL_EXPORTER_OTLP_PROTOCOL": "grpc",
      ]
    )
    defer {
      Task {
        await daemon.stop()
      }
    }

    HarnessMonitorTelemetry.shared.resetForTests()
    HarnessMonitorTelemetry.shared.bootstrap(using: environment)

    let transport = WebSocketTransport(connection: daemon.connection)
    try await transport.connect()
    _ = try await transport.sessions()
    await transport.shutdown()
    HarnessMonitorTelemetry.shared.shutdown()
    await daemon.stop()

    try await waitForTraceExport(timeout: .seconds(5)) {
      let spans = collector.traceCollector.exportedSpans
      let hasMonitorWebSocketSpan = spans.contains {
        $0.serviceName == "harness-monitor" && $0.name == "daemon.websocket.rpc"
      }
      let hasDaemonSessionsSpan = spans.contains {
        $0.serviceName == "harness-daemon" && $0.name == "sessions"
      }
      return hasMonitorWebSocketSpan && hasDaemonSessionsSpan
    }

    let spans = collector.traceCollector.exportedSpans
    let monitorSpan = try #require(
      spans.last {
        $0.serviceName == "harness-monitor" && $0.name == "daemon.websocket.rpc"
      }
    )
    let daemonSpan = try #require(
      spans.last {
        $0.serviceName == "harness-daemon" && $0.name == "sessions"
      }
    )

    #expect(monitorSpan.kind == .client)
    #expect(daemonSpan.kind == .server)
    #expect(monitorSpan.traceID == daemonSpan.traceID)
    #expect(daemonSpan.parentSpanID == monitorSpan.spanID)
  }
}

@Suite("Harness Monitor observability smoke", .serialized)
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
    let modelContainer = try HarnessMonitorModelContainer.live(using: environment)
    let cacheService = SessionCacheService(
      modelContainer: modelContainer,
      databaseURL: HarnessMonitorPaths.harnessRoot(using: environment)
        .appendingPathComponent("harness-cache.store")
    )
    let cacheCounts = await cacheService.recordCounts()
    let entries = try await client.timeline(sessionID: "observability-smoke", scope: .summary)
    HarnessMonitorTelemetry.shared.shutdown()

    #expect(cacheCounts.sessions == 0)
    #expect(entries.count == 1)
  }

  @Test("Collector-configured smoke emits real daemon websocket spans")
  func collectorConfiguredSmokeEmitsRealDaemonWebSocketSpans() async throws {
    defer {
      HarnessMonitorTelemetry.shared.resetForTests()
    }

    let resolvedSmokeConfig = try HarnessMonitorObservabilityConfig.resolve(using: smokeEnvironment())
    guard let smokeConfig = resolvedSmokeConfig, smokeConfig.monitorSmokeEnabled else {
      return
    }

    let temporaryHome = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryHome) }

    let xdgDataHome = temporaryHome.appendingPathComponent("xdg-data", isDirectory: true)
    let daemonDataHome = temporaryHome.appendingPathComponent("daemon-data", isDirectory: true)
    try FileManager.default.createDirectory(at: xdgDataHome, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: daemonDataHome, withIntermediateDirectories: true)
    try writeSharedConfig(homeDirectory: xdgDataHome, grpcEndpoint: "http://127.0.0.1:4317")

    let environment = HarnessMonitorEnvironment(
      values: [
        "XDG_DATA_HOME": xdgDataHome.path,
        HarnessMonitorAppGroup.daemonDataHomeEnvironmentKey: daemonDataHome.path,
      ],
      homeDirectory: temporaryHome
    )
    let daemon = try await LiveDaemonFixture.start(
      xdgDataHome: xdgDataHome,
      daemonDataHome: daemonDataHome,
      environmentOverrides: liveCollectorEnvironmentOverrides(from: smokeConfig)
    )
    defer {
      Task {
        await daemon.stop()
      }
    }

    HarnessMonitorTelemetry.shared.bootstrap(using: environment)
    let transport = WebSocketTransport(connection: daemon.connection)
    try await transport.connect()
    _ = try await transport.sessions()
    await transport.shutdown()
    HarnessMonitorTelemetry.shared.shutdown()
    // Keep the test host alive long enough for the live collector/Tempo path
    // to observe the flushed websocket client span before xctest tears down.
    try await Task.sleep(for: .seconds(2))
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

private struct LiveDaemonFixture {
  let process: Process
  let connection: HarnessMonitorConnection

  static func start(
    xdgDataHome: URL,
    daemonDataHome: URL,
    environmentOverrides: [String: String] = [:]
  ) async throws -> Self {
    let manifestURL = daemonDataHome
      .appendingPathComponent("harness", isDirectory: true)
      .appendingPathComponent("daemon", isDirectory: true)
      .appendingPathComponent("manifest.json")
    try FileManager.default.createDirectory(
      at: manifestURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
      "-c",
      "cd \"\(repoRoot().path)\" && scripts/cargo-local.sh run --quiet -- daemon serve --host 127.0.0.1 --port 0",
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

private func liveCollectorEnvironmentOverrides(
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

private func repoRoot(filePath: StaticString = #filePath) -> URL {
  URL(fileURLWithPath: "\(filePath)")
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
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
  private let lock = NSLock()
  private(set) var receivedSpans = [Opentelemetry_Proto_Trace_V1_ResourceSpans]()

  var hasReceivedSpans: Bool {
    lock.withLock {
      receivedSpans.isEmpty == false
    }
  }

  var serviceNames: Set<String> {
    lock.withLock {
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
  }

  var exportedSpans: [CollectedTraceSpan] {
    lock.withLock {
      receivedSpans.flatMap { resourceSpans in
        let serviceName =
          resourceSpans.resource.attributes.first { $0.key == "service.name" }?.value.stringValue ?? ""
        return resourceSpans.scopeSpans.flatMap { scopeSpans in
          scopeSpans.spans.map { span in
            CollectedTraceSpan(
              serviceName: serviceName,
              name: span.name,
              kind: span.kind,
              traceID: hexString(span.traceID),
              spanID: hexString(span.spanID),
              parentSpanID: hexString(span.parentSpanID)
            )
          }
        }
      }
    }
  }

  func export(
    request: Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceRequest,
    context: StatusOnlyCallContext
  ) -> EventLoopFuture<Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceResponse> {
    lock.withLock {
      receivedSpans.append(contentsOf: request.resourceSpans)
    }
    return context.eventLoop.makeSucceededFuture(
      Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceResponse()
    )
  }
}

private struct CollectedTraceSpan: Equatable {
  let serviceName: String
  let name: String
  let kind: Opentelemetry_Proto_Trace_V1_Span.SpanKind
  let traceID: String
  let spanID: String
  let parentSpanID: String
}

private func hexString(_ data: Data) -> String {
  data.map { String(format: "%02x", $0) }.joined()
}

private func waitForTraceExport(
  timeout: Duration,
  predicate: @escaping @Sendable () -> Bool
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now + timeout
  while clock.now < deadline {
    if predicate() {
      return
    }
    try await Task.sleep(for: .milliseconds(100))
  }
  throw URLError(.timedOut)
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
