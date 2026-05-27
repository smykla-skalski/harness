import Foundation
import os
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

  /// Counts how often each instrumented view body re-evaluates inside a
  /// measured step so a perf scenario can prove which subtrees re-run per
  /// frame. Resolved once at launch, so the per-eval guard collapses to a
  /// single bool check and stays inert in normal app runs.
  private static let bodyEvalCountingActive: Bool = activeScenario != nil
  private static let bodyEvalCounts = OSAllocatedUnfairLock(initialState: [String: Int]())

  public static func countBodyEval(_ view: String) {
    guard bodyEvalCountingActive else { return }
    bodyEvalCounts.withLock { $0[view, default: 0] += 1 }
  }

  public static func resetBodyEvalCounts() {
    guard bodyEvalCountingActive else { return }
    bodyEvalCounts.withLock { $0.removeAll(keepingCapacity: true) }
  }

  public static func flushBodyEvalCounts(label: String) {
    guard bodyEvalCountingActive else { return }
    let snapshot = bodyEvalCounts.withLock { $0 }
    guard !snapshot.isEmpty else { return }
    let details = snapshot.reduce(into: [String: String]()) { result, entry in
      result[entry.key] = String(entry.value)
    }
    recordScenarioEvent(component: "view.body.counts", event: label, details: details)
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
