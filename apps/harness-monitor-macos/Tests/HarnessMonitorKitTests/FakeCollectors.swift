import Darwin
import Foundation
import GRPC
import NIO
import OpenTelemetryProtocolExporterCommon
import OpenTelemetryProtocolExporterGrpc

final class GRPCCollectorServer: @unchecked Sendable {
  let traceCollector = FakeTraceCollector()
  let logCollector = FakeLogCollector()
  let metricCollector = FakeMetricCollector()

  private let group = PlatformSupport.makeEventLoopGroup(loopCount: 1)
  private let server: Server

  let endpoint: URL

  convenience init() throws {
    try self.init(port: 0)
  }

  init(port: Int) throws {
    server = try Server.insecure(group: group)
      .withServiceProviders([traceCollector, logCollector, metricCollector])
      .bind(host: "127.0.0.1", port: port)
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

final class ReservedLoopbackPort {
  let port: UInt16

  init() throws {
    let fileDescriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard fileDescriptor >= 0 else {
      throw URLError(.cannotCreateFile)
    }

    var reuse: Int32 = 1
    _ = setsockopt(
      fileDescriptor,
      SOL_SOCKET,
      SO_REUSEADDR,
      &reuse,
      socklen_t(MemoryLayout<Int32>.size)
    )

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
      Darwin.close(fileDescriptor)
      throw URLError(.badURL)
    }

    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
        Darwin.bind(
          fileDescriptor,
          generic,
          socklen_t(MemoryLayout<sockaddr_in>.size)
        )
      }
    }
    guard bindResult == 0, Darwin.listen(fileDescriptor, 1) == 0 else {
      Darwin.close(fileDescriptor)
      throw URLError(.cannotCreateFile)
    }

    var boundAddress = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
        getsockname(fileDescriptor, generic, &length)
      }
    }
    guard nameResult == 0 else {
      Darwin.close(fileDescriptor)
      throw URLError(.cannotCreateFile)
    }

    port = UInt16(bigEndian: boundAddress.sin_port)
    Darwin.close(fileDescriptor)
  }
}

final class FakeTraceCollector: Opentelemetry_Proto_Collector_Trace_V1_TraceServiceProvider {
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
        let serviceNameAttr =
          resourceSpans.resource.attributes.first { $0.key == "service.name" }
        let serviceName = serviceNameAttr?.value.stringValue ?? ""
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

struct CollectedTraceSpan: Equatable {
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

func waitForTraceExport(
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

final class FakeLogCollector: Opentelemetry_Proto_Collector_Logs_V1_LogsServiceProvider {
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

final class FakeMetricCollector: Opentelemetry_Proto_Collector_Metrics_V1_MetricsServiceProvider {
  var interceptors:
    Opentelemetry_Proto_Collector_Metrics_V1_MetricsServiceServerInterceptorFactoryProtocol?
  private let lock = NSLock()
  private(set) var receivedMetrics = [Opentelemetry_Proto_Metrics_V1_ResourceMetrics]()

  var hasReceivedMetrics: Bool {
    lock.withLock {
      receivedMetrics.isEmpty == false
    }
  }

  var metricNames: Set<String> {
    lock.withLock {
      Set(
        receivedMetrics.flatMap { resourceMetrics in
          resourceMetrics.scopeMetrics.flatMap { scopeMetrics in
            scopeMetrics.metrics.map(\.name)
          }
        }
      )
    }
  }

  var resourceAttributes: [(key: String, value: String)] {
    lock.withLock {
      receivedMetrics.flatMap { resourceMetrics in
        resourceMetrics.resource.attributes.map { ($0.key, $0.value.stringValue) }
      }
    }
  }

  var serviceNames: Set<String> {
    lock.withLock {
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
  }

  func dataPointsForMetric(_ name: String) -> [MetricDataPoint] {
    lock.withLock {
      receivedMetrics.flatMap { resourceMetrics in
        resourceMetrics.scopeMetrics.flatMap { scopeMetrics in
          scopeMetrics.metrics.filter { $0.name == name }.flatMap { metric in
            extractDataPoints(from: metric)
          }
        }
      }
    }
  }

  func export(
    request: Opentelemetry_Proto_Collector_Metrics_V1_ExportMetricsServiceRequest,
    context: StatusOnlyCallContext
  ) -> EventLoopFuture<Opentelemetry_Proto_Collector_Metrics_V1_ExportMetricsServiceResponse> {
    lock.withLock {
      receivedMetrics.append(contentsOf: request.resourceMetrics)
    }
    return context.eventLoop.makeSucceededFuture(
      Opentelemetry_Proto_Collector_Metrics_V1_ExportMetricsServiceResponse()
    )
  }
}

struct MetricDataPoint {
  let attributes: [String: String]
}

private func extractDataPoints(
  from metric: Opentelemetry_Proto_Metrics_V1_Metric
) -> [MetricDataPoint] {
  var points: [MetricDataPoint] = []

  switch metric.data {
  case .sum(let sum):
    for dp in sum.dataPoints {
      let pairs = dp.attributes.map { ($0.key, attributeStringValue($0.value)) }
      points.append(MetricDataPoint(attributes: Dictionary(uniqueKeysWithValues: pairs)))
    }
  case .gauge(let gauge):
    for dp in gauge.dataPoints {
      let pairs = dp.attributes.map { ($0.key, attributeStringValue($0.value)) }
      points.append(MetricDataPoint(attributes: Dictionary(uniqueKeysWithValues: pairs)))
    }
  case .histogram(let histogram):
    for dp in histogram.dataPoints {
      let pairs = dp.attributes.map { ($0.key, attributeStringValue($0.value)) }
      points.append(MetricDataPoint(attributes: Dictionary(uniqueKeysWithValues: pairs)))
    }
  case .exponentialHistogram, .summary, .none:
    break
  }

  return points
}

private func attributeStringValue(
  _ value: Opentelemetry_Proto_Common_V1_AnyValue
) -> String {
  switch value.value {
  case .stringValue(let string):
    string
  case .boolValue(let bool):
    bool ? "true" : "false"
  case .intValue(let int):
    String(int)
  case .doubleValue(let double):
    String(double)
  case .arrayValue(let array):
    array.values.map(attributeStringValue).joined(separator: ",")
  case .kvlistValue(let list):
    list.values
      .map { "\($0.key)=\(attributeStringValue($0.value))" }
      .joined(separator: ",")
  case .bytesValue(let bytes):
    bytes.map { String(format: "%02x", $0) }.joined()
  case .none:
    ""
  }
}
