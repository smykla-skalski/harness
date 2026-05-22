import HarnessMonitorKit
import SwiftUI

private struct DashboardWindowPerfScenarioTrigger: Equatable {
  let rawValue: String?
}

struct DashboardWindowPerfScenarioScript: ViewModifier {
  @Binding var selectedRoute: DashboardWindowRoute
  @Binding var searchAutomationCommand: AppSearchAutomationCommand

  @State private var appliedScenarioRawValue: String?

  private var trigger: DashboardWindowPerfScenarioTrigger {
    DashboardWindowPerfScenarioTrigger(
      rawValue: HarnessMonitorUITestEnvironment.perfScenarioRawValue
    )
  }

  func body(content: Content) -> some View {
    content
      .task(id: trigger) {
        await applyScenarioIfNeeded(trigger)
      }
  }

  private func applyScenarioIfNeeded(_ trigger: DashboardWindowPerfScenarioTrigger) async {
    guard let scenario = trigger.rawValue else { return }
    guard appliedScenarioRawValue != scenario else { return }

    let baseScenario = HarnessMonitorUITestEnvironment.basePerfScenario(for: scenario)
    switch baseScenario {
    case "dashboard-search-suggestions":
      appliedScenarioRawValue = scenario
      recordScriptBegin(baseScenario: baseScenario)
      await runDashboardSearchSuggestionsScript()
    default:
      return
    }

    HarnessMonitorPerfTrace.recordScenarioEvent(
      event: "script.complete",
      details: ["base_scenario": baseScenario]
    )
  }

  private func recordScriptBegin(baseScenario: String) {
    HarnessMonitorPerfTrace.recordScenarioEvent(
      event: "script.begin",
      details: ["base_scenario": baseScenario]
    )
  }

  private func runDashboardSearchSuggestionsScript() async {
    await runMeasuredStep("route.reviews") {
      selectedRoute = .reviews
      await Task.yield()
      try? await Task.sleep(for: .milliseconds(180))
    }
    await runMeasuredStep("search.present") {
      updateSearchAutomation(query: "", isPresented: true)
      await Task.yield()
      try? await Task.sleep(for: .milliseconds(240))
    }

    for query in searchQueries {
      await runMeasuredStep("query.\(query)") {
        updateSearchAutomation(query: query, isPresented: true)
        try? await Task.sleep(for: .milliseconds(260))
      }
    }

    await runMeasuredStep("search.dismiss") {
      updateSearchAutomation(query: "", isPresented: false)
    }
  }

  private var searchQueries: [String] {
    [
      "renovte",
      "smykla",
      "security",
      "renovte",
    ]
  }

  private func runMeasuredStep(
    _ step: String,
    details: [String: String] = [:],
    operation: () async -> Void
  ) async {
    let interval = HarnessMonitorPerfTrace.beginStep(step, details: details)
    await operation()
    HarnessMonitorPerfTrace.endStep(interval, details: details)
  }

  private func updateSearchAutomation(query: String, isPresented: Bool) {
    searchAutomationCommand = AppSearchAutomationCommand(
      generation: searchAutomationCommand.generation &+ 1,
      query: query,
      isPresented: isPresented
    )
  }
}
