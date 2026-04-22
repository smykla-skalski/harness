import Foundation
import OpenTelemetryApi

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

struct HarnessMonitorTelemetryExportControl {
  let forceFlush: () -> Void
  let shutdown: () -> Void
  let closeTransport: () -> Void
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
  private let sqliteOperationCounter: HarnessMonitorLongCounterRecorder
  private let sqliteOperationDuration: HarnessMonitorDoubleHistogramRecorder
  private let sqliteErrorCounter: HarnessMonitorLongCounterRecorder
  private let sqliteFileSizeGauge: HarnessMonitorLongGaugeRecorder
  private let sqliteRecordCountGauge: HarnessMonitorLongGaugeRecorder
  private let phase1: HarnessMonitorTelemetryPhase1Instruments

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
    let sqliteOperationCounter =
      meter
      .counterBuilder(name: "harness_monitor_sqlite_operations_total")
      .build()
    let sqliteOperationDuration =
      meter
      .histogramBuilder(name: "harness_monitor_sqlite_operation_duration_ms")
      .build()
    let sqliteErrorCounter =
      meter
      .counterBuilder(name: "harness_monitor_sqlite_errors_total")
      .build()
    let sqliteFileSizeGauge =
      meter
      .gaugeBuilder(name: "harness_monitor_sqlite_file_size_bytes")
      .ofLongs()
      .build()
    let sqliteRecordCountGauge =
      meter
      .gaugeBuilder(name: "harness_monitor_sqlite_record_count")
      .ofLongs()
      .build()

    httpRequestCounter = HarnessMonitorLongCounterRecorder(counter: httpCounter)
    httpRequestDuration = HarnessMonitorDoubleHistogramRecorder(histogram: httpDuration)
    websocketConnectCounter = HarnessMonitorLongCounterRecorder(counter: websocketCounter)
    websocketRPCDuration = HarnessMonitorDoubleHistogramRecorder(histogram: websocketDuration)
    self.sqliteOperationCounter = HarnessMonitorLongCounterRecorder(counter: sqliteOperationCounter)
    self.sqliteOperationDuration = HarnessMonitorDoubleHistogramRecorder(
      histogram: sqliteOperationDuration
    )
    self.sqliteErrorCounter = HarnessMonitorLongCounterRecorder(counter: sqliteErrorCounter)
    self.sqliteFileSizeGauge = HarnessMonitorLongGaugeRecorder(gauge: sqliteFileSizeGauge)
    self.sqliteRecordCountGauge = HarnessMonitorLongGaugeRecorder(gauge: sqliteRecordCountGauge)
    phase1 = HarnessMonitorTelemetryPhase1Instruments(meter: meter)
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

  func recordSQLiteOperation(
    operation: String,
    access: String,
    database: String,
    durationMs: Double,
    failed: Bool
  ) {
    let attributes = sqliteAttributes(
      operation: operation,
      access: access,
      database: database
    )
    sqliteOperationCounter.add(value: 1, attributes: attributes)
    sqliteOperationDuration.record(value: durationMs, attributes: attributes)
    if failed {
      sqliteErrorCounter.add(value: 1, attributes: attributes)
    }
  }

  func recordSQLiteFileSize(
    database: String,
    path: String,
    sizeBytes: Int64
  ) {
    sqliteFileSizeGauge.record(
      value: Int(clamping: sizeBytes),
      attributes: [
        "db.system": .string("sqlite"),
        "db.name": .string(database),
        "db.file": .string((path as NSString).lastPathComponent),
      ]
    )
  }

  func recordSQLiteRecordCount(
    database: String,
    entity: String,
    count: Int
  ) {
    sqliteRecordCountGauge.record(
      value: count,
      attributes: [
        "db.system": .string("sqlite"),
        "db.name": .string(database),
        "db.entity": .string(entity),
      ]
    )
  }

  func recordAppLifecycleEvent(
    event: String,
    launchMode: String,
    durationMs: Double?
  ) {
    phase1.recordAppLifecycleEvent(event: event, launchMode: launchMode, durationMs: durationMs)
  }

  func recordBootstrapPhase(
    phase: String,
    launchMode: String,
    durationMs: Double,
    failed: Bool
  ) {
    phase1.recordBootstrapPhase(
      phase: phase,
      launchMode: launchMode,
      durationMs: durationMs,
      failed: failed
    )
  }

  func recordUserInteraction(
    interaction: String,
    sessionID: String?,
    durationMs: Double
  ) {
    phase1.recordUserInteraction(
      interaction: interaction,
      sessionID: sessionID,
      durationMs: durationMs
    )
  }

  func recordCacheRead(
    operation: String,
    hit: Bool,
    durationMs: Double
  ) {
    phase1.recordCacheRead(operation: operation, hit: hit, durationMs: durationMs)
  }

  func recordResourceMetrics(
    residentMemoryBytes: Int64,
    virtualMemoryBytes: Int64
  ) {
    phase1.recordResourceMetrics(
      residentMemoryBytes: residentMemoryBytes,
      virtualMemoryBytes: virtualMemoryBytes
    )
  }

  func recordActiveTasks(_ count: Int) {
    phase1.recordActiveTasks(count)
  }

  func recordWebSocketConnections(_ count: Int) {
    phase1.recordWebSocketConnections(count)
  }

  func recordAPIError(
    endpoint: String,
    method: String,
    errorType: String,
    statusCode: Int?
  ) {
    phase1.recordAPIError(
      endpoint: endpoint,
      method: method,
      errorType: errorType,
      statusCode: statusCode
    )
  }

  func recordDecodingError(
    entity: String,
    reason: String
  ) {
    phase1.recordDecodingError(entity: entity, reason: reason)
  }

  func recordTimeoutError(
    operation: String,
    durationMs: Double
  ) {
    phase1.recordTimeoutError(operation: operation, durationMs: durationMs)
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

  private func sqliteAttributes(
    operation: String,
    access: String,
    database: String
  ) -> [String: AttributeValue] {
    [
      "db.system": .string("sqlite"),
      "db.operation.name": .string(operation),
      "db.access": .string(access),
      "db.name": .string(database),
    ]
  }
}
