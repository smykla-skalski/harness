import Foundation

import OpenTelemetryApi

/// Span-name constants and telemetry accessors for the Monitor supervisor loop. Phase 1 ships
/// the stable names up front so rule/executor/service code landing in Phase 2 can open spans
/// without a signature change.
public enum SupervisorTelemetry {
  public static let tickSpanName = "supervisor.tick"
  public static let ruleEvalSpanName = "supervisor.rule.evaluate"
  public static let actionDispatchSpanName = "supervisor.action.dispatch"
  public static let actionExecuteSpanName = "supervisor.action.execute"

  public static func tracer() -> Tracer {
    OpenTelemetry.instance.tracerProvider.get(
      instrumentationName: "io.harnessmonitor.supervisor",
      instrumentationVersion: nil
    )
  }

  public static func meter() -> Meter {
    OpenTelemetry.instance.meterProvider.get(
      instrumentationName: "io.harnessmonitor.supervisor",
      instrumentationVersion: nil
    )
  }
}
