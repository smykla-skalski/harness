import Foundation
import OpenTelemetryApi
import OpenTelemetryProtocolExporterHttp
import OpenTelemetrySdk

private struct HarnessMonitorHeaderSetter: Setter {
  func set(carrier: inout [String: String], key: String, value: String) {
    carrier[key] = value
  }
}

public final class HarnessMonitorTelemetry: @unchecked Sendable {
  public static let shared = HarnessMonitorTelemetry()

  struct State {
    var bootstrapped = false
    var instruments: HarnessMonitorTelemetryInstruments?
    var exportControl: HarnessMonitorTelemetryExportControl?
    var httpExporterSessionOverride: URLSession?
  }

  let stateLock = NSLock()
  var state = State()

  private init() {}

  public func bootstrap(
    using environment: HarnessMonitorEnvironment = .current,
    bundle: Bundle = .main
  ) {
    let shouldBootstrap = stateLock.withLock { () -> Bool in
      guard state.bootstrapped == false else {
        return false
      }
      state.bootstrapped = true
      return true
    }

    guard shouldBootstrap else {
      return
    }

    let resource = buildResource(environment: environment, bundle: bundle)
    let config: HarnessMonitorObservabilityConfig?
    do {
      config = try HarnessMonitorObservabilityConfig.resolve(using: environment)
    } catch {
      HarnessMonitorLogger.lifecycle.error(
        "Failed to load observability config: \(error.localizedDescription, privacy: .public)"
      )
      config = nil
    }

    OpenTelemetry.registerPropagators(
      textPropagators: [W3CTraceContextPropagator()],
      baggagePropagator: W3CBaggagePropagator()
    )
    OpenTelemetry.registerFeedbackHandler { message in
      HarnessMonitorLogger.lifecycle.warning(
        "OpenTelemetry feedback: \(message, privacy: .public)"
      )
    }

    let registration = registerProviders(resource: resource, config: config)

    let instruments = HarnessMonitorTelemetryInstruments(
      meterProvider: registration.meterProvider
    )
    stateLock.withLock {
      state.instruments = instruments
      state.exportControl = registration.exportControl
    }

    emitLog(
      name: "observability.bootstrap",
      severity: .info,
      body: config == nil
        ? "Harness Monitor telemetry bootstrapped without exporter."
        : "Harness Monitor telemetry bootstrapped with exporter.",
      attributes: bootstrapAttributes(config: config)
    )
  }

  func decorate(
    _ request: inout URLRequest,
    spanContext: SpanContext? = nil
  ) -> String {
    bootstrap()

    let requestID = UUID().uuidString
    request.setValue(requestID, forHTTPHeaderField: "X-Request-Id")

    for (header, value) in traceContext(spanContext: spanContext) {
      request.setValue(value, forHTTPHeaderField: header)
    }
    return requestID
  }

  func traceContext(spanContext: SpanContext? = nil) -> [String: String] {
    bootstrap()

    var carrier: [String: String] = [:]
    let activeSpanContext =
      spanContext
      ?? OpenTelemetry.instance.contextProvider.activeSpan?.context
    if let activeSpanContext, activeSpanContext.isValid {
      OpenTelemetry.instance.propagators.textMapPropagator.inject(
        spanContext: activeSpanContext,
        carrier: &carrier,
        setter: HarnessMonitorHeaderSetter()
      )
    }
    if let baggage = OpenTelemetry.instance.contextProvider.activeBaggage {
      OpenTelemetry.instance.propagators.textMapBaggagePropagator.inject(
        baggage: baggage,
        carrier: &carrier,
        setter: HarnessMonitorHeaderSetter()
      )
    }
    return carrier
  }

  func startSpan(
    name: String,
    kind: SpanKind = .internal,
    attributes: [String: AttributeValue] = [:]
  ) -> any Span {
    bootstrap()

    let tracer = OpenTelemetry.instance.tracerProvider.get(
      instrumentationName: HarnessMonitorTelemetryConstants.tracerScope
    )
    let spanBuilder = tracer.spanBuilder(spanName: name).setSpanKind(spanKind: kind)
    for (key, value) in attributes {
      spanBuilder.setAttribute(key: key, value: value)
    }
    return spanBuilder.startSpan()
  }

  func recordError(
    _ error: Error,
    on span: any SpanBase,
    attributes: [String: AttributeValue] = [:]
  ) {
    if let recorder = span as? any Span {
      recorder.recordException(error, attributes: attributes)
      return
    }

    var eventAttributes = attributes
    let nsError = error as NSError
    eventAttributes["exception.type"] = .string("\(nsError.code)")
    eventAttributes["exception.message"] = .string(nsError.localizedDescription)
    eventAttributes["exception.domain"] = .string(nsError.domain)
    span.addEvent(name: "exception", attributes: eventAttributes)
  }

  func recordHTTPRequest(
    method: String,
    path: String,
    statusCode: Int?,
    durationMs: Double,
    failed: Bool
  ) {
    bootstrap()
    let instruments = stateLock.withLock { state.instruments }
    instruments?.recordHTTPRequest(
      method: method,
      path: path,
      statusCode: statusCode,
      durationMs: durationMs,
      failed: failed
    )
  }

  func recordWebSocketConnect(outcome: String) {
    bootstrap()
    let instruments = stateLock.withLock { state.instruments }
    instruments?.recordWebSocketConnect(outcome: outcome)
  }

  func recordWebSocketRPC(method: String, durationMs: Double, failed: Bool) {
    bootstrap()
    let instruments = stateLock.withLock { state.instruments }
    instruments?.recordWebSocketRPC(method: method, durationMs: durationMs, failed: failed)
  }

  func emitLog(
    name: String,
    severity: Severity,
    body: String,
    attributes: [String: AttributeValue] = [:]
  ) {
    bootstrap()
    let logger = OpenTelemetry.instance.loggerProvider.get(
      instrumentationScopeName: HarnessMonitorTelemetryConstants.loggerScope
    )
    logger.logRecordBuilder()
      .setEventName(name)
      .setSeverity(severity)
      .setBody(.string(body))
      .setAttributes(attributes)
      .emit()
  }

  public func shutdown() {
    let exportControl = stateLock.withLock { () -> HarnessMonitorTelemetryExportControl? in
      let exportControl = state.exportControl
      state.exportControl = nil
      return exportControl
    }
    exportControl?.forceFlush()
    exportControl?.shutdown()
  }

  func setHTTPExporterSessionForTests(_ session: URLSession?) {
    stateLock.withLock {
      state.httpExporterSessionOverride = session
    }
  }

  func resetForTests() {
    let exportControl = stateLock.withLock { () -> HarnessMonitorTelemetryExportControl? in
      let exportControl = state.exportControl
      state = State()
      return exportControl
    }

    exportControl?.shutdown()
    OpenTelemetry.registerTracerProvider(tracerProvider: DefaultTracerProvider.instance)
    OpenTelemetry.registerLoggerProvider(loggerProvider: DefaultLoggerProvider.instance)
    OpenTelemetry.registerMeterProvider(meterProvider: DefaultMeterProvider.instance)
    OpenTelemetry.registerPropagators(
      textPropagators: [W3CTraceContextPropagator()],
      baggagePropagator: W3CBaggagePropagator()
    )
  }

  func makeHTTPExporterClient() -> any HTTPClient {
    let session = stateLock.withLock { state.httpExporterSessionOverride }
    guard let session else {
      return BaseHTTPClient()
    }
    return BaseHTTPClient(session: session)
  }
}
