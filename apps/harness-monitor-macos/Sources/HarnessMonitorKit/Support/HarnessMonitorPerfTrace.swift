import Foundation

public enum HarnessMonitorPerfTrace {
  private static let scenarioEnvironmentKey = "HARNESS_MONITOR_PERF_SCENARIO"

  public static var activeScenario: String? {
    let scenario = ProcessInfo.processInfo.environment[scenarioEnvironmentKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let scenario, !scenario.isEmpty else { return nil }
    return scenario
  }

  public static func recordScenarioEvent(
    component: String = "perf.scenario",
    event: String,
    details: [String: String] = [:]
  ) {
    var payload = details
    if let scenario = activeScenario {
      payload["scenario"] = scenario
    }
    HarnessMonitorUITestTrace.recordPerf(
      component: component,
      event: event,
      details: payload
    )
  }

  public static func recordStep(
    _ step: String,
    component: String = "perf.scenario",
    details: [String: String] = [:]
  ) {
    var payload = details
    payload["step"] = step
    recordScenarioEvent(component: component, event: "step", details: payload)
  }
}
