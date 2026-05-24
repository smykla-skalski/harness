import Foundation
import OSLog

public struct HarnessMonitorPerfStepInterval {
  fileprivate let step: String
  fileprivate let state: OSSignpostIntervalState
}

public enum HarnessMonitorPerfTrace {
  private static let scenarioEnvironmentKey = "HARNESS_MONITOR_PERF_SCENARIO"
  private static let signposter = OSSignposter(
    subsystem: "io.harnessmonitor",
    category: "perf"
  )

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
    signposter.emitEvent(
      "perf_event",
      "component=\(component) event=\(event)"
    )
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

  public static func beginStep(
    _ step: String,
    component: String = "perf.scenario",
    details: [String: String] = [:]
  ) -> HarnessMonitorPerfStepInterval {
    var payload = details
    payload["step"] = step
    let state = signposter.beginInterval("perf_step", "step=\(step)")
    recordScenarioEvent(component: component, event: "step.begin", details: payload)
    return HarnessMonitorPerfStepInterval(step: step, state: state)
  }

  public static func endStep(
    _ interval: HarnessMonitorPerfStepInterval,
    component: String = "perf.scenario",
    details: [String: String] = [:]
  ) {
    var payload = details
    payload["step"] = interval.step
    signposter.endInterval("perf_step", interval.state)
    recordScenarioEvent(component: component, event: "step.end", details: payload)
  }
}
