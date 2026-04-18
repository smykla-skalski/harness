import OpenTelemetryApi

struct HarnessMonitorHeaderSetter: Setter {
  func set(carrier: inout [String: String], key: String, value: String) {
    carrier[key] = value
  }
}

enum HarnessMonitorTelemetryTaskContext {
  @TaskLocal static var parentSpanContext: SpanContext?
}

extension HarnessMonitorTelemetry {
  func withActiveSpan<T>(
    _ span: SpanBase,
    _ operation: () throws -> T
  ) rethrows -> T {
    try OpenTelemetryApi.OpenTelemetry.instance.contextProvider.withActiveSpan(span, operation)
  }

  func withActiveSpan<T>(
    _ span: SpanBase,
    _ operation: () async throws -> T
  ) async rethrows -> T {
    try await OpenTelemetryApi.OpenTelemetry.instance.contextProvider.withActiveSpan(
      span,
      operation
    )
  }
}
