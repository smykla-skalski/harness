import Foundation
import GRPC
import NIO
import OpenTelemetryApi
import OpenTelemetryProtocolExporterCommon
import OpenTelemetryProtocolExporterGrpc
import OpenTelemetryProtocolExporterHttp
import OpenTelemetrySdk

extension HarnessMonitorTelemetry {
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

    let osVersion = ProcessInfo.processInfo.operatingSystemVersion
    let osVersionString =
      "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
    let userAgent = "HarnessMonitor/\(serviceVersion) (macOS \(osVersionString))"

    return EnvVarResource.get(environment: environment.values).merging(
      other: Resource(
        attributes: [
          "service.namespace": .string(HarnessMonitorTelemetryConstants.serviceNamespace),
          "service.name": .string(HarnessMonitorTelemetryConstants.serviceName),
          "service.version": .string(serviceVersion),
          "deployment.environment.name": .string(deploymentName),
          "service.instance.id": .string(UUID().uuidString),
          "os.type": .string("darwin"),
          "os.version": .string(osVersionString),
          "host.arch": .string(hostArchitecture()),
          "user_agent.original": .string(userAgent),
          "device.id": .string(kernelUUID()),
        ]
      )
    )
  }

  func kernelUUID() -> String {
    var size: Int = 0
    sysctlbyname("kern.uuid", nil, &size, nil, 0)
    guard size > 0 else {
      return "unknown"
    }
    var uuid = [CChar](repeating: 0, count: size)
    sysctlbyname("kern.uuid", &uuid, &size, nil, 0)
    let data = Data(uuid.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) })
    return String(bytes: data, encoding: .utf8) ?? "unknown"
  }

  func hostArchitecture() -> String {
    #if arch(arm64)
      return "arm64"
    #elseif arch(x86_64)
      return "x86_64"
    #else
      return "unknown"
    #endif
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

  func registerProviders(
    resource: Resource,
    config: HarnessMonitorObservabilityConfig?,
    environment: HarnessMonitorEnvironment = .current
  ) -> HarnessMonitorTelemetryRegistration {
    if let config {
      return registerExportingProviders(
        resource: resource,
        config: config,
        environment: environment
      )
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
    config: HarnessMonitorObservabilityConfig,
    environment: HarnessMonitorEnvironment = .current,
    deferredExportActivation: DeferredExportActivation? = nil
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
      let exporters = bufferedExportersIfNeeded(
        traceExporter: traceExporter,
        logExporter: logExporter,
        metricExporter: metricExporter,
        environment: environment,
        activation: deferredExportActivation
      )
      return registerProviders(
        resource: resource,
        traceExporter: exporters.traceExporter,
        logExporter: exporters.logExporter,
        metricExporter: exporters.metricExporter,
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
    traceExporter: any SpanExporter,
    logExporter: any LogRecordExporter,
    metricExporter: any MetricExporter,
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
        _ = traceExporter.flush(
          explicitTimeout: HarnessMonitorTelemetryConstants.exportTimeoutSeconds
        )
        _ = logExporter.forceFlush(
          explicitTimeout: HarnessMonitorTelemetryConstants.exportTimeoutSeconds
        )
        _ = metricExporter.flush()
        exportControl?.forceFlush()
      },
      shutdown: {
        tracerProvider.forceFlush(timeout: HarnessMonitorTelemetryConstants.exportTimeoutSeconds)
        _ = logProcessor.forceFlush(
          explicitTimeout: HarnessMonitorTelemetryConstants.exportTimeoutSeconds
        )
        _ = meterProvider.forceFlush()
        _ = traceExporter.flush(
          explicitTimeout: HarnessMonitorTelemetryConstants.exportTimeoutSeconds
        )
        _ = logExporter.forceFlush(
          explicitTimeout: HarnessMonitorTelemetryConstants.exportTimeoutSeconds
        )
        _ = metricExporter.flush()
        tracerProvider.shutdown()
        _ = logProcessor.shutdown(
          explicitTimeout: HarnessMonitorTelemetryConstants.exportTimeoutSeconds
        )
        _ = meterProvider.shutdown()
        exportControl?.shutdown()
      },
      closeTransport: {
        exportControl?.closeTransport()
      }
    )
    return HarnessMonitorTelemetryRegistration(
      meterProvider: meterProvider,
      exportControl: control
    )
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
      },
      closeTransport: {
        for channel in channels {
          _ = try? channel.close().wait()
        }
        try? group.syncShutdownGracefully()
      }
    )
  }
}
