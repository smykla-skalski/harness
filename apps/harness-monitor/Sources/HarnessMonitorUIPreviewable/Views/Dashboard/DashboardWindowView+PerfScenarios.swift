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
    HarnessMonitorPerfTrace.resetBodyEvalCounts()
    await operation()
    HarnessMonitorPerfTrace.flushBodyEvalCounts(label: step)
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

/// Drives the Dashboard sidebar collapse/expand the way a user does from the
/// titlebar toggle, cycling every route so the detail content under the
/// animating column varies. Lives at the window level because that is where the
/// `columnVisibility` binding is owned, mirroring `SessionWindowPerfScenarioScript`.
struct DashboardSidebarTogglePerfScript: ViewModifier {
  @Binding var columnVisibility: NavigationSplitViewVisibility
  @Binding var selectedRoute: DashboardWindowRoute

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
    guard
      HarnessMonitorUITestEnvironment.basePerfScenario(for: scenario)
        == "dashboard-sidebar-toggle"
    else { return }

    appliedScenarioRawValue = scenario
    HarnessMonitorPerfTrace.recordScenarioEvent(
      event: "script.begin",
      details: ["base_scenario": "dashboard-sidebar-toggle"]
    )
    await runDashboardSidebarToggleScript()
    HarnessMonitorPerfTrace.recordScenarioEvent(
      event: "script.complete",
      details: ["base_scenario": "dashboard-sidebar-toggle"]
    )
  }

  private func runDashboardSidebarToggleScript() async {
    await runMeasuredStep("column.double-column") {
      columnVisibility = .doubleColumn
      await Task.yield()
      try? await Task.sleep(for: .milliseconds(300))
    }

    for route in DashboardWindowRoute.allCases {
      await runMeasuredStep("selection.route.\(route.rawValue)") {
        selectedRoute = route
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(220))
      }
      await runMeasuredStep("column.detail-only") {
        columnVisibility = .detailOnly
        try? await Task.sleep(for: .milliseconds(450))
      }
      await runMeasuredStep("column.double-column") {
        columnVisibility = .doubleColumn
        try? await Task.sleep(for: .milliseconds(450))
      }
    }
  }

  private func runMeasuredStep(
    _ step: String,
    details: [String: String] = [:],
    operation: () async -> Void
  ) async {
    let interval = HarnessMonitorPerfTrace.beginStep(step, details: details)
    HarnessMonitorPerfTrace.resetBodyEvalCounts()
    await operation()
    HarnessMonitorPerfTrace.flushBodyEvalCounts(label: step)
    HarnessMonitorPerfTrace.endStep(interval, details: details)
  }
}
