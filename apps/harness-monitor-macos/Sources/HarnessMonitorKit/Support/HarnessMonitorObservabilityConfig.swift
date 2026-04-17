import Foundation

enum HarnessMonitorObservabilityConfigSource: Equatable, Sendable {
  case environment
  case sharedFile
  case toggle
}

enum HarnessMonitorObservabilityTransport: Equatable, Sendable {
  case grpc
  case httpProtobuf
}

struct HarnessMonitorHTTPSignalEndpoints: Equatable, Sendable {
  let traces: URL
  let metrics: URL
  let logs: URL
}

struct HarnessMonitorObservabilityConfig: Equatable, Sendable {
  let source: HarnessMonitorObservabilityConfigSource
  let transport: HarnessMonitorObservabilityTransport
  let grpcEndpoint: URL?
  let httpSignalEndpoints: HarnessMonitorHTTPSignalEndpoints?
  let grafanaURL: URL?
  let headers: [String: String]

  static func resolve(
    using environment: HarnessMonitorEnvironment = .current,
    loadData: (URL) throws -> Data = { try Data(contentsOf: $0) }
  ) throws -> Self? {
    if let config = resolveFromEnvironment(using: environment) {
      return config
    }

    if let config = try resolveFromSharedFile(using: environment, loadData: loadData) {
      return config
    }

    if isTruthy(environment.values["HARNESS_OTEL_EXPORT"]) {
      return defaultToggleConfig(using: environment)
    }

    return nil
  }
}

private struct SharedObservabilityFile: Decodable {
  let enabled: Bool
  let grpcEndpoint: String
  let httpEndpoint: String
  let grafanaURL: String?
  let headers: [String: String]

  enum CodingKeys: String, CodingKey {
    case enabled
    case grpcEndpoint = "grpc_endpoint"
    case httpEndpoint = "http_endpoint"
    case grafanaURL = "grafana_url"
    case headers
  }
}

private enum HarnessMonitorHTTPSignal: String {
  case traces
  case metrics
  case logs
}

extension HarnessMonitorObservabilityConfig {
  fileprivate static func resolveFromEnvironment(
    using environment: HarnessMonitorEnvironment
  ) -> Self? {
    let values = environment.values
    let baseEndpoint = url(from: values["OTEL_EXPORTER_OTLP_ENDPOINT"])
    let tracesEndpoint = url(from: values["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"])
    let metricsEndpoint = url(from: values["OTEL_EXPORTER_OTLP_METRICS_ENDPOINT"])
    let logsEndpoint = url(from: values["OTEL_EXPORTER_OTLP_LOGS_ENDPOINT"])

    guard
      baseEndpoint != nil
        || tracesEndpoint != nil
        || metricsEndpoint != nil
        || logsEndpoint != nil
    else {
      return nil
    }

    let transport = resolveTransport(
      protocolOverride: normalized(values["OTEL_EXPORTER_OTLP_PROTOCOL"]),
      baseEndpoint: baseEndpoint,
      tracesEndpoint: tracesEndpoint,
      metricsEndpoint: metricsEndpoint,
      logsEndpoint: logsEndpoint
    )
    let headers = parseHeaders(normalized(values["OTEL_EXPORTER_OTLP_HEADERS"]))

    switch transport {
    case .grpc:
      let endpoint = baseEndpoint ?? tracesEndpoint ?? metricsEndpoint ?? logsEndpoint
      return Self(
        source: .environment,
        transport: .grpc,
        grpcEndpoint: endpoint,
        httpSignalEndpoints: nil,
        grafanaURL: url(from: values["HARNESS_OTEL_GRAFANA_URL"]),
        headers: headers
      )
    case .httpProtobuf:
      guard
        let endpoints = resolveHTTPSignalEndpoints(
          baseEndpoint: baseEndpoint,
          tracesEndpoint: tracesEndpoint,
          metricsEndpoint: metricsEndpoint,
          logsEndpoint: logsEndpoint
        )
      else {
        return nil
      }

      return Self(
        source: .environment,
        transport: .httpProtobuf,
        grpcEndpoint: nil,
        httpSignalEndpoints: endpoints,
        grafanaURL: url(from: values["HARNESS_OTEL_GRAFANA_URL"]),
        headers: headers
      )
    }
  }

  fileprivate static func resolveFromSharedFile(
    using environment: HarnessMonitorEnvironment,
    loadData: (URL) throws -> Data
  ) throws -> Self? {
    let configURL = HarnessMonitorPaths.sharedObservabilityConfigURL(using: environment)
    guard FileManager.default.fileExists(atPath: configURL.path) else {
      return nil
    }

    let decoder = JSONDecoder()
    let sharedFile = try decoder.decode(SharedObservabilityFile.self, from: loadData(configURL))
    guard sharedFile.enabled else {
      return nil
    }

    let transport = resolveTransport(
      protocolOverride: normalized(environment.values["OTEL_EXPORTER_OTLP_PROTOCOL"]),
      baseEndpoint: nil,
      tracesEndpoint: nil,
      metricsEndpoint: nil,
      logsEndpoint: nil
    )

    switch transport {
    case .grpc:
      return Self(
        source: .sharedFile,
        transport: .grpc,
        grpcEndpoint: url(from: sharedFile.grpcEndpoint),
        httpSignalEndpoints: nil,
        grafanaURL: url(from: sharedFile.grafanaURL),
        headers: sharedFile.headers
      )
    case .httpProtobuf:
      guard
        let baseEndpoint = url(from: sharedFile.httpEndpoint),
        let endpoints = resolveHTTPSignalEndpoints(
          baseEndpoint: baseEndpoint,
          tracesEndpoint: nil,
          metricsEndpoint: nil,
          logsEndpoint: nil
        )
      else {
        return nil
      }

      return Self(
        source: .sharedFile,
        transport: .httpProtobuf,
        grpcEndpoint: nil,
        httpSignalEndpoints: endpoints,
        grafanaURL: url(from: sharedFile.grafanaURL),
        headers: sharedFile.headers
      )
    }
  }

  fileprivate static func defaultToggleConfig(
    using environment: HarnessMonitorEnvironment
  ) -> Self? {
    let transport = resolveTransport(
      protocolOverride: normalized(environment.values["OTEL_EXPORTER_OTLP_PROTOCOL"]),
      baseEndpoint: nil,
      tracesEndpoint: nil,
      metricsEndpoint: nil,
      logsEndpoint: nil
    )

    switch transport {
    case .grpc:
      return Self(
        source: .toggle,
        transport: .grpc,
        grpcEndpoint: URL(string: "http://127.0.0.1:4317"),
        httpSignalEndpoints: nil,
        grafanaURL: nil,
        headers: [:]
      )
    case .httpProtobuf:
      guard
        let endpoints = resolveHTTPSignalEndpoints(
          baseEndpoint: URL(string: "http://127.0.0.1:4318"),
          tracesEndpoint: nil,
          metricsEndpoint: nil,
          logsEndpoint: nil
        )
      else {
        return nil
      }

      return Self(
        source: .toggle,
        transport: .httpProtobuf,
        grpcEndpoint: nil,
        httpSignalEndpoints: endpoints,
        grafanaURL: nil,
        headers: [:]
      )
    }
  }

  fileprivate static func resolveTransport(
    protocolOverride: String?,
    baseEndpoint: URL?,
    tracesEndpoint: URL?,
    metricsEndpoint: URL?,
    logsEndpoint: URL?
  ) -> HarnessMonitorObservabilityTransport {
    if protocolOverride == "http/protobuf" {
      return .httpProtobuf
    }
    if tracesEndpoint != nil || metricsEndpoint != nil || logsEndpoint != nil {
      return .httpProtobuf
    }
    if let baseEndpoint, shouldInferHTTPTransport(from: baseEndpoint) {
      return .httpProtobuf
    }
    return .grpc
  }

  fileprivate static func resolveHTTPSignalEndpoints(
    baseEndpoint: URL?,
    tracesEndpoint: URL?,
    metricsEndpoint: URL?,
    logsEndpoint: URL?
  ) -> HarnessMonitorHTTPSignalEndpoints? {
    guard
      let baseEndpoint = baseEndpoint ?? tracesEndpoint ?? metricsEndpoint ?? logsEndpoint
    else {
      return nil
    }
    let defaultEndpoints = defaultHTTPSignalEndpoints(from: baseEndpoint)
    return HarnessMonitorHTTPSignalEndpoints(
      traces: tracesEndpoint ?? defaultEndpoints.traces,
      metrics: metricsEndpoint ?? defaultEndpoints.metrics,
      logs: logsEndpoint ?? defaultEndpoints.logs
    )
  }

  fileprivate static func defaultHTTPSignalEndpoints(
    from baseEndpoint: URL
  ) -> HarnessMonitorHTTPSignalEndpoints {
    let signalRoot = defaultHTTPSignalRoot(from: baseEndpoint)
    return HarnessMonitorHTTPSignalEndpoints(
      traces: append(signal: .traces, to: signalRoot),
      metrics: append(signal: .metrics, to: signalRoot),
      logs: append(signal: .logs, to: signalRoot)
    )
  }

  fileprivate static func defaultHTTPSignalRoot(from baseEndpoint: URL) -> URL {
    let lastComponent = baseEndpoint.lastPathComponent.lowercased()
    if lastComponent == HarnessMonitorHTTPSignal.traces.rawValue
      || lastComponent == HarnessMonitorHTTPSignal.metrics.rawValue
      || lastComponent == HarnessMonitorHTTPSignal.logs.rawValue
    {
      return baseEndpoint.deletingLastPathComponent()
    }
    if baseEndpoint.lastPathComponent.lowercased() == "v1" {
      return baseEndpoint
    }
    return baseEndpoint.appendingPathComponent("v1", isDirectory: true)
  }

  fileprivate static func append(
    signal: HarnessMonitorHTTPSignal,
    to baseURL: URL
  ) -> URL {
    baseURL.appendingPathComponent(signal.rawValue)
  }

  fileprivate static func shouldInferHTTPTransport(from baseEndpoint: URL) -> Bool {
    if baseEndpoint.port == 4318 {
      return true
    }

    let path = baseEndpoint.path.lowercased()
    return path.hasSuffix("/v1")
      || path.hasSuffix("/v1/traces")
      || path.hasSuffix("/v1/metrics")
      || path.hasSuffix("/v1/logs")
  }
}

private func url(from rawValue: String?) -> URL? {
  guard let normalizedValue = normalized(rawValue) else {
    return nil
  }
  return URL(string: normalizedValue)
}

private func normalized(_ rawValue: String?) -> String? {
  guard
    let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
    !rawValue.isEmpty
  else {
    return nil
  }
  return rawValue
}

private func parseHeaders(_ rawValue: String?) -> [String: String] {
  guard let rawValue else {
    return [:]
  }
  var headers: [String: String] = [:]
  for entry in rawValue.split(separator: ",") {
    let parts = entry.split(separator: "=", maxSplits: 1)
    guard parts.count == 2 else {
      continue
    }
    let key = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
    let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty, !value.isEmpty else {
      continue
    }
    headers[key] = value
  }
  return headers
}

private func isTruthy(_ rawValue: String?) -> Bool {
  guard let normalizedValue = normalized(rawValue)?.lowercased() else {
    return false
  }
  return normalizedValue == "1"
    || normalizedValue == "true"
    || normalizedValue == "yes"
    || normalizedValue == "on"
}
