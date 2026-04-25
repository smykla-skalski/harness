import Foundation

@testable import HarnessMonitorKit

func liveCollectorEnvironmentOverrides(
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

func waitForAllSignalExports(
  collector: GRPCCollectorServer,
  environment: HarnessMonitorEnvironment,
  timeout: Duration = .seconds(5)
) async throws {
  do {
    try await waitForTraceExport(timeout: timeout) {
      collector.traceCollector.hasReceivedSpans
        && collector.logCollector.hasReceivedLogs
        && collector.metricCollector.hasReceivedMetrics
    }
  } catch {
    print(deferredExportDebugSummary(collector: collector, environment: environment))
    throw error
  }
}

private func deferredExportDebugSummary(
  collector: GRPCCollectorServer,
  environment: HarnessMonitorEnvironment
) -> String {
  let bufferRoot =
    HarnessMonitorPaths.harnessRoot(using: environment)
    .appendingPathComponent("observability", isDirectory: true)
    .appendingPathComponent("otlp-buffer", isDirectory: true)
  let traceFiles = bufferedExportFileNames(signal: "traces", bufferRoot: bufferRoot)
  let logFiles = bufferedExportFileNames(signal: "logs", bufferRoot: bufferRoot)
  let metricFiles = bufferedExportFileNames(signal: "metrics", bufferRoot: bufferRoot)

  return [
    "deferred export debug:",
    "traces=\(collector.traceCollector.exportedSpans.count)",
    "logs=\(collector.logCollector.receivedLogs.count)",
    "metrics=\(collector.metricCollector.receivedMetrics.count)",
    "traceFiles=\(traceFiles)",
    "logFiles=\(logFiles)",
    "metricFiles=\(metricFiles)",
  ].joined(separator: " ")
}

private func bufferedExportFileNames(signal: String, bufferRoot: URL) -> [String] {
  let signalRoot = bufferRoot.appendingPathComponent(signal, isDirectory: true)
  let entries = try? FileManager.default.contentsOfDirectory(
    at: signalRoot,
    includingPropertiesForKeys: nil
  )
  return (entries ?? []).map(\.lastPathComponent)
}
