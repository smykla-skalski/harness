import Foundation
import GRPC
import NIO
import OpenTelemetryApi
import OpenTelemetryProtocolExporterCommon
import OpenTelemetryProtocolExporterGrpc
import OpenTelemetryProtocolExporterHttp
import OpenTelemetrySdk

enum HarnessMonitorTelemetryConstants {
  static let serviceName = "harness-monitor"
  static let serviceNamespace = "harness"
  static let tracerScope = "io.harnessmonitor.transport"
  static let loggerScope = "io.harnessmonitor.logs"
  static let meterScope = "io.harnessmonitor.metrics"
  static let exportTimeoutSeconds: TimeInterval = 10
  static let metricExportIntervalSeconds: TimeInterval = 5
  static let spanScheduleDelaySeconds: TimeInterval = 1
  static let logScheduleDelaySeconds: TimeInterval = 1
}

func harnessMonitorDurationMilliseconds(_ duration: Duration) -> Double {
  Double(duration.components.seconds) * 1_000
    + Double(duration.components.attoseconds) / 1_000_000_000_000_000
}

final class HarnessMonitorLongCounterRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var counter: any LongCounter

  init(counter: some LongCounter) {
    self.counter = counter
  }

  func add(value: Int, attributes: [String: AttributeValue]) {
    lock.withLock {
      counter.add(value: value, attributes: attributes)
    }
  }
}

final class HarnessMonitorDoubleHistogramRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var histogram: any DoubleHistogram

  init(histogram: some DoubleHistogram) {
    self.histogram = histogram
  }

  func record(value: Double, attributes: [String: AttributeValue]) {
    lock.withLock {
      histogram.record(value: value, attributes: attributes)
    }
  }
}

struct HarnessMonitorTelemetryExportControl {
  let forceFlush: () -> Void
  let shutdown: () -> Void
}

struct HarnessMonitorTelemetryRegistration {
  let meterProvider: any MeterProvider
  let exportControl: HarnessMonitorTelemetryExportControl?
}

final class HarnessMonitorTelemetryInstruments: @unchecked Sendable {
  private let httpRequestCounter: HarnessMonitorLongCounterRecorder
  private let httpRequestDuration: HarnessMonitorDoubleHistogramRecorder
  private let websocketConnectCounter: HarnessMonitorLongCounterRecorder
  private let websocketRPCDuration: HarnessMonitorDoubleHistogramRecorder

  init(meterProvider: any MeterProvider) {
    let meter =
      meterProvider
      .meterBuilder(name: HarnessMonitorTelemetryConstants.meterScope)
      .build()

    let httpCounter = meter.counterBuilder(name: "harness_monitor_http_requests_total").build()
    let httpDuration = meter.histogramBuilder(name: "harness_monitor_http_request_duration_ms")
      .build()
    let websocketCounter =
      meter
      .counterBuilder(name: "harness_monitor_websocket_connects_total")
      .build()
    let websocketDuration =
      meter
      .histogramBuilder(name: "harness_monitor_websocket_rpc_duration_ms")
      .build()

    httpRequestCounter = HarnessMonitorLongCounterRecorder(counter: httpCounter)
    httpRequestDuration = HarnessMonitorDoubleHistogramRecorder(histogram: httpDuration)
    websocketConnectCounter = HarnessMonitorLongCounterRecorder(counter: websocketCounter)
    websocketRPCDuration = HarnessMonitorDoubleHistogramRecorder(histogram: websocketDuration)
  }

  func recordHTTPRequest(
    method: String,
    path: String,
    statusCode: Int?,
    durationMs: Double,
    failed: Bool
  ) {
    let attributes = baseRequestAttributes(
      method: method,
      path: path,
      statusCode: statusCode,
      failed: failed
    )
    httpRequestCounter.add(value: 1, attributes: attributes)
    httpRequestDuration.record(value: durationMs, attributes: attributes)
  }

  func recordWebSocketConnect(outcome: String) {
    websocketConnectCounter.add(
      value: 1,
      attributes: [
        "transport.kind": .string("websocket"),
        "connect.outcome": .string(outcome),
      ]
    )
  }

  func recordWebSocketRPC(method: String, durationMs: Double, failed: Bool) {
    websocketRPCDuration.record(
      value: durationMs,
      attributes: [
        "transport.kind": .string("websocket"),
        "rpc.method": .string(method),
        "rpc.failed": .bool(failed),
      ]
    )
  }

  private func baseRequestAttributes(
    method: String,
    path: String,
    statusCode: Int?,
    failed: Bool
  ) -> [String: AttributeValue] {
    var attributes: [String: AttributeValue] = [
      "transport.kind": .string("http"),
      "http.request.method": .string(method),
      "url.path": .string(path),
      "request.failed": .bool(failed),
    ]
    if let statusCode {
      attributes["http.response.status_code"] = .int(statusCode)
    }
    return attributes
  }
}

extension HarnessMonitorTelemetry {
  func registerProviders(
    resource: Resource,
    config: HarnessMonitorObservabilityConfig?
  ) -> HarnessMonitorTelemetryRegistration {
    if let config {
      return registerExportingProviders(resource: resource, config: config)
    }

    OpenTelemetry.registerTracerProvider(
      tracerProvider: TracerProviderBuilder()
        .with(resource: resource)
        .build()
    )
    OpenTelemetry.registerLoggerProvider(
      loggerProvider: LoggerProviderBuilder()
        .with(resource: resource)
        .build()
    )
    return HarnessMonitorTelemetryRegistration(
      meterProvider: OpenTelemetry.instance.meterProvider,
      exportControl: nil
    )
  }

  func registerExportingProviders(
    resource: Resource,
    config: HarnessMonitorObservabilityConfig
  ) -> HarnessMonitorTelemetryRegistration {
    let otlpHeaders = config.headers.map { ($0.key, $0.value) }
    let otlpConfig = OtlpConfiguration(
      timeout: HarnessMonitorTelemetryConstants.exportTimeoutSeconds,
      compression: .gzip,
      headers: otlpHeaders.isEmpty ? nil : otlpHeaders,
      exportAsJson: false
    )

    switch config.transport {
    case .grpc:
      guard let grpcEndpoint = config.grpcEndpoint else {
        return registerProviders(resource: resource, config: nil)
      }

      let group = PlatformSupport.makeEventLoopGroup(loopCount: 1)
      let traceChannel = makeGRPCChannel(endpoint: grpcEndpoint, group: group)
      let logChannel = makeGRPCChannel(endpoint: grpcEndpoint, group: group)
      let metricChannel = makeGRPCChannel(endpoint: grpcEndpoint, group: group)
      let traceExporter = OtlpTraceExporter(
        channel: traceChannel,
        config: otlpConfig,
        envVarHeaders: nil
      )
      let logExporter = OtlpLogExporter(
        channel: logChannel,
        config: otlpConfig,
        envVarHeaders: nil
      )
      let metricExporter = OtlpMetricExporter(
        channel: metricChannel,
        config: otlpConfig,
        envVarHeaders: nil
      )
      return registerProviders(
        resource: resource,
        traceExporter: traceExporter,
        logExporter: logExporter,
        metricExporter: metricExporter,
        exportControl: makeExportControl(
          channels: [traceChannel, logChannel, metricChannel],
          group: group
        )
      )
    case .httpProtobuf:
      guard let endpoints = config.httpSignalEndpoints else {
        return registerProviders(resource: resource, config: nil)
      }

      let httpClient = makeHTTPExporterClient()
      let traceExporter = OtlpHttpTraceExporter(
        endpoint: endpoints.traces,
        config: otlpConfig,
        httpClient: httpClient,
        envVarHeaders: nil
      )
      let logExporter = OtlpHttpLogExporter(
        endpoint: endpoints.logs,
        config: otlpConfig,
        httpClient: httpClient,
        envVarHeaders: nil
      )
      let metricExporter = OtlpHttpMetricExporter(
        endpoint: endpoints.metrics,
        config: otlpConfig,
        httpClient: httpClient,
        envVarHeaders: nil
      )
      return registerProviders(
        resource: resource,
        traceExporter: traceExporter,
        logExporter: logExporter,
        metricExporter: metricExporter,
        exportControl: nil
      )
    }
  }

  func registerProviders(
    resource: Resource,
    traceExporter: some SpanExporter,
    logExporter: some LogRecordExporter,
    metricExporter: some MetricExporter,
    exportControl: HarnessMonitorTelemetryExportControl?
  ) -> HarnessMonitorTelemetryRegistration {
    let spanProcessor = BatchSpanProcessor(
      spanExporter: traceExporter,
      scheduleDelay: HarnessMonitorTelemetryConstants.spanScheduleDelaySeconds,
      exportTimeout: HarnessMonitorTelemetryConstants.exportTimeoutSeconds
    )
    let tracerProvider = TracerProviderBuilder()
      .with(resource: resource)
      .add(spanProcessor: spanProcessor)
      .build()

    let logProcessor = BatchLogRecordProcessor(
      logRecordExporter: logExporter,
      scheduleDelay: HarnessMonitorTelemetryConstants.logScheduleDelaySeconds,
      exportTimeout: HarnessMonitorTelemetryConstants.exportTimeoutSeconds
    )
    let loggerProvider = LoggerProviderBuilder()
      .with(resource: resource)
      .with(processors: [logProcessor])
      .build()

    let metricReader = PeriodicMetricReaderBuilder(exporter: metricExporter)
      .setInterval(
        timeInterval: HarnessMonitorTelemetryConstants.metricExportIntervalSeconds
      )
      .build()
    let meterProvider = MeterProviderSdk.builder()
      .setResource(resource: resource)
      .registerView(
        selector: InstrumentSelector.builder().setInstrument(name: ".*").build(),
        view: View.builder().build()
      )
      .registerMetricReader(reader: metricReader)
      .build()

    OpenTelemetry.registerTracerProvider(tracerProvider: tracerProvider)
    OpenTelemetry.registerLoggerProvider(loggerProvider: loggerProvider)
    OpenTelemetry.registerMeterProvider(meterProvider: meterProvider)
    let control = HarnessMonitorTelemetryExportControl(
      forceFlush: {
        tracerProvider.forceFlush(timeout: HarnessMonitorTelemetryConstants.exportTimeoutSeconds)
        _ = logProcessor.forceFlush(
          explicitTimeout: HarnessMonitorTelemetryConstants.exportTimeoutSeconds
        )
        _ = meterProvider.forceFlush()
        exportControl?.forceFlush()
      },
      shutdown: {
        tracerProvider.forceFlush(timeout: HarnessMonitorTelemetryConstants.exportTimeoutSeconds)
        _ = logProcessor.forceFlush(
          explicitTimeout: HarnessMonitorTelemetryConstants.exportTimeoutSeconds
        )
        _ = meterProvider.forceFlush()
        tracerProvider.shutdown()
        _ = logProcessor.shutdown(
          explicitTimeout: HarnessMonitorTelemetryConstants.exportTimeoutSeconds
        )
        _ = meterProvider.shutdown()
        exportControl?.shutdown()
      }
    )
    return HarnessMonitorTelemetryRegistration(
      meterProvider: meterProvider,
      exportControl: control
    )
  }

  func buildResource(
    environment: HarnessMonitorEnvironment,
    bundle: Bundle
  ) -> Resource {
    let serviceVersion =
      bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
      ?? "dev"
    let launchMode = HarnessMonitorLaunchMode(environment: environment)
    let deploymentName: String
    switch launchMode {
    case .live:
      deploymentName = "local"
    case .preview:
      deploymentName = "preview"
    case .empty:
      deploymentName = "empty"
    }

    return EnvVarResource.get(environment: environment.values).merging(
      other: Resource(
        attributes: [
          "service.namespace": .string(HarnessMonitorTelemetryConstants.serviceNamespace),
          "service.name": .string(HarnessMonitorTelemetryConstants.serviceName),
          "service.version": .string(serviceVersion),
          "deployment.environment.name": .string(deploymentName),
          "service.instance.id": .string(UUID().uuidString),
        ]
      )
    )
  }

  func bootstrapAttributes(
    config: HarnessMonitorObservabilityConfig?
  ) -> [String: AttributeValue] {
    guard let config else {
      return [
        "otel.export.enabled": .bool(false)
      ]
    }
    let configSource: String
    switch config.source {
    case .environment:
      configSource = "environment"
    case .sharedFile:
      configSource = "shared_file"
    case .toggle:
      configSource = "toggle"
    }

    var attributes: [String: AttributeValue] = [
      "otel.export.enabled": .bool(true),
      "otel.export.transport": .string(
        config.transport == .grpc ? "grpc" : "http/protobuf"
      ),
      "otel.config.source": .string(configSource),
    ]
    if let endpoint = config.grpcEndpoint?.absoluteString {
      attributes["otel.export.endpoint"] = .string(endpoint)
    } else if let tracesEndpoint = config.httpSignalEndpoints?.traces.absoluteString {
      attributes["otel.export.endpoint"] = .string(tracesEndpoint)
    }
    return attributes
  }

  func makeGRPCChannel(
    endpoint: URL,
    group: EventLoopGroup
  ) -> ClientConnection {
    let host = endpoint.host(percentEncoded: false) ?? "127.0.0.1"
    let port = endpoint.port ?? 4317
    let scheme = endpoint.scheme?.lowercased()

    if scheme == "https" || scheme == "grpcs" {
      return ClientConnection.usingPlatformAppropriateTLS(for: group)
        .connect(host: host, port: port)
    }

    return ClientConnection.insecure(group: group)
      .connect(host: host, port: port)
  }

  func makeExportControl(
    channels: [ClientConnection],
    group: EventLoopGroup
  ) -> HarnessMonitorTelemetryExportControl {
    HarnessMonitorTelemetryExportControl(
      forceFlush: {},
      shutdown: {
        for channel in channels {
          _ = try? channel.close().wait()
        }
        try? group.syncShutdownGracefully()
      }
    )
  }
}
