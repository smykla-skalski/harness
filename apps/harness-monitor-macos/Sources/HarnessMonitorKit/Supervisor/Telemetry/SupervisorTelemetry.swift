import Foundation

import OpenTelemetryApi

/// Span-name constants and telemetry accessors for the Monitor supervisor loop. Phase 1 ships
/// the stable names up front so rule/executor/service code landing in Phase 2 can open spans
/// without a signature change. Meter accessors are added in Phase 2 once per-rule counters are
/// defined — the existing `HarnessMonitorTelemetry` pipeline owns the concrete `MeterProvider`
/// registration.
public enum SupervisorTelemetry {
  public static let tickSpanName = "supervisor.tick"
  public static let ruleEvalSpanName = "supervisor.rule.evaluate"
  public static let actionDispatchSpanName = "supervisor.action.dispatch"
  public static let actionExecuteSpanName = "supervisor.action.execute"

  public static let instrumentationName = "io.harnessmonitor.supervisor"

  public static func tracer() -> any Tracer {
    OpenTelemetry.instance.tracerProvider.get(
      instrumentationName: instrumentationName,
      instrumentationVersion: nil
    )
  }
}
