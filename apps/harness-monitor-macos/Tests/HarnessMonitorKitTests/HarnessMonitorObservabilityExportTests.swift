import Foundation
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
    let metricNames = collector.metricCollector.metricNames
    #expect(metricNames.contains("harness_monitor_http_requests_total"))
    #expect(metricNames.contains("harness_monitor_sqlite_operations_total"))
    #expect(metricNames.contains("harness_monitor_sqlite_file_size_bytes"))
    #expect(
      collector.traceCollector.exportedSpans.contains {
        $0.serviceName == "harness-monitor" && $0.name == "monitor.sqlite.open_cache_store"
      }
    )
    #expect(
      collector.traceCollector.exportedSpans.contains {
        $0.serviceName == "harness-monitor" && $0.name == "monitor.sqlite.record_counts"
      }
    )
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
    _ = try await transport.health()
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

  @Test("gRPC export keeps bootstrap, transport, daemon server, and daemon db spans on one trace")
  func grpcExportKeepsBootstrapTransportDaemonServerAndDbSpansOnOneTrace() async throws {
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
    _ = try await transport.health()
    _ = await makeBootstrappedStore(client: transport)
    await transport.shutdown()
    HarnessMonitorTelemetry.shared.shutdown()
    await daemon.stop()

    try await waitForTraceExport(timeout: .seconds(5)) {
      let spans = collector.traceCollector.exportedSpans
      return hasBootstrapTransportTrace(spans)
    }

    try assertBootstrapTransportTrace(collector.traceCollector.exportedSpans)
  }

  @Test("gRPC export preserves pre-collector root spans until the loopback collector is reachable")
  func grpcExportPreservesPreCollectorRootSpansUntilLoopbackCollectorIsReachable() async throws {
    let reservedPort = try ReservedLoopbackPort()
    let endpoint = URL(string: "http://127.0.0.1:\(reservedPort.port)")!
    let temporaryHome = try temporaryDirectory()
    let environment = HarnessMonitorEnvironment(
      values: [
        "OTEL_EXPORTER_OTLP_ENDPOINT": endpoint.absoluteString,
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
    let startupSpan = HarnessMonitorTelemetry.shared.startSpan(
      name: "app.lifecycle.deferred_bootstrap",
      kind: .internal
    )
    startupSpan.end()
    HarnessMonitorTelemetry.shared.recordAppLifecycleEvent(
      event: "bootstrap",
      launchMode: "live",
      durationMs: 25
    )

    #expect(
      HarnessMonitorTelemetry.shared.stateLock.withLock {
        HarnessMonitorTelemetry.shared.state.deferredExportActivation != nil
      }
    )
    #expect(
      HarnessMonitorTelemetry.shared.stateLock.withLock {
        HarnessMonitorTelemetry.shared.state.exportControl != nil
      }
    )

    let collector = try GRPCCollectorServer(port: Int(reservedPort.port))
    defer {
      collector.shutdown()
      HarnessMonitorTelemetry.shared.resetForTests()
    }

    let activationDeadline = ContinuousClock().now + .seconds(3)
    while ContinuousClock().now < activationDeadline {
      HarnessMonitorTelemetry.shared.bootstrap(using: environment)
      _ = try await client.timeline(sessionID: "grpc-deferred-export", scope: .summary)
      let exportActivated = HarnessMonitorTelemetry.shared.stateLock.withLock {
        HarnessMonitorTelemetry.shared.state.deferredExportActivation == nil
      }
      if exportActivated {
        break
      }
      try await Task.sleep(for: .milliseconds(100))
    }

    #expect(
      HarnessMonitorTelemetry.shared.stateLock.withLock {
        HarnessMonitorTelemetry.shared.state.deferredExportActivation == nil
      }
    )
    let activationSpan = HarnessMonitorTelemetry.shared.startSpan(
      name: "app.lifecycle.deferred_bootstrap_activated",
      kind: .internal
    )
    activationSpan.end()
    HarnessMonitorTelemetry.shared.forceFlush()
    HarnessMonitorTelemetry.shared.shutdown()

    try await waitForAllSignalExports(
      collector: collector,
      environment: environment
    )

    #expect(collector.traceCollector.hasReceivedSpans)
    #expect(collector.logCollector.hasReceivedLogs)
    #expect(collector.metricCollector.hasReceivedMetrics)
    #expect(
      collector.traceCollector.exportedSpans.contains {
        $0.serviceName == "harness-monitor"
          && $0.name == "app.lifecycle.deferred_bootstrap"
      }
    )
  }
}

private func hasBootstrapTransportTrace(_ spans: [CollectedTraceSpan]) -> Bool {
  let hasBootstrapSpan = spans.contains {
    $0.serviceName == "harness-monitor" && $0.name == "app.lifecycle.bootstrap"
  }
  let hasMonitorClientSpan = spans.contains {
    $0.serviceName == "harness-monitor" && $0.name == "daemon.websocket.rpc"
  }
  let hasDaemonSessionsSpan = spans.contains {
    $0.serviceName == "harness-daemon" && $0.name == "sessions"
  }
  let hasDaemonDbSpan = spans.contains {
    $0.serviceName == "harness-daemon" && $0.name == "daemon.db.async.list_session_summaries"
  }
  return hasBootstrapSpan && hasMonitorClientSpan && hasDaemonSessionsSpan && hasDaemonDbSpan
}

private func assertBootstrapTransportTrace(_ spans: [CollectedTraceSpan]) throws {
  let bootstrapSpan = try #require(
    spans.last {
      $0.serviceName == "harness-monitor" && $0.name == "app.lifecycle.bootstrap"
    }
  )
  let initialConnectSpan = try #require(
    spans.last {
      $0.serviceName == "harness-monitor"
        && $0.name == "app.lifecycle.bootstrap.managed_initial_connect"
        && $0.traceID == bootstrapSpan.traceID
    }
  )
  let monitorClientSpans = spans.filter {
    $0.serviceName == "harness-monitor"
      && $0.name == "daemon.websocket.rpc"
      && $0.traceID == bootstrapSpan.traceID
  }
  let daemonSpan = try #require(
    spans.last {
      $0.serviceName == "harness-daemon"
        && $0.name == "sessions"
        && $0.traceID == bootstrapSpan.traceID
    }
  )
  let dbSpan = try #require(
    spans.last {
      $0.serviceName == "harness-daemon"
        && $0.name == "daemon.db.async.list_session_summaries"
        && $0.traceID == bootstrapSpan.traceID
    }
  )

  #expect(initialConnectSpan.parentSpanID == bootstrapSpan.spanID)
  #expect(monitorClientSpans.isEmpty == false)
  #expect(monitorClientSpans.contains { $0.parentSpanID == initialConnectSpan.spanID })
  #expect(monitorClientSpans.contains { $0.spanID == daemonSpan.parentSpanID })
  #expect(dbSpan.parentSpanID == daemonSpan.spanID)
}
