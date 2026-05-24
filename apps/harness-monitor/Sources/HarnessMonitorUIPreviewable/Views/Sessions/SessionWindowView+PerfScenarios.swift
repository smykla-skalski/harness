import HarnessMonitorKit
import SwiftUI

extension SessionWindowView {
  var searchAutomation: AppSearchAutomationState? {
    HarnessMonitorUITestEnvironment.isPerfScenarioActive ? stateCache.appSearchAutomation : nil
  }
}

private struct SessionWindowPerfScenarioTrigger: Equatable {
  let rawValue: String?
  let sessionID: String
  let hasSearchCorpus: Bool
  let sidebarToggleTargets: [SessionSidebarToggleTarget]
}

struct SessionWindowPerfScenarioScript: ViewModifier {
  let stateCache: SessionWindowStateCache
  @Binding var columnVisibility: NavigationSplitViewVisibility
  let contentDetailBaseWidth: Double
  @Binding var contentDetailDividerWidth: Double?
  let sessionID: String
  let snapshot: HarnessMonitorSessionWindowSnapshot?
  let decisionIDs: [String]

  @State private var appliedScenarioRawValue: String?

  private var trigger: SessionWindowPerfScenarioTrigger {
    SessionWindowPerfScenarioTrigger(
      rawValue: HarnessMonitorUITestEnvironment.perfScenarioRawValue,
      sessionID: sessionID,
      hasSearchCorpus: hasSearchCorpus,
      sidebarToggleTargets: sidebarToggleTargets
    )
  }

  private var hasSearchCorpus: Bool {
    guard let snapshot, let detail = snapshot.detail else {
      return false
    }
    return !detail.agents.isEmpty || !detail.tasks.isEmpty || !snapshot.timeline.isEmpty
  }

  private var sidebarToggleTargets: [SessionSidebarToggleTarget] {
    guard let snapshot, let detail = snapshot.detail else {
      return []
    }
    var targets: [SessionSidebarToggleTarget] = []
    if let agentID = detail.agents.first?.agentId {
      targets.append(.agent(agentID))
    }
    if let taskID = detail.tasks.first?.taskId {
      targets.append(.task(taskID))
    }
    if let decisionID = decisionIDs.first {
      targets.append(.decision(decisionID))
    }
    if !snapshot.timeline.isEmpty {
      targets.append(.route(.timeline))
    }
    return targets
  }

  func body(content: Content) -> some View {
    content
      .task(id: trigger) {
        await applyScenarioIfNeeded(trigger)
      }
  }

  private func applyScenarioIfNeeded(_ trigger: SessionWindowPerfScenarioTrigger) async {
    guard let scenario = trigger.rawValue else { return }
    guard trigger.sessionID == PreviewFixtures.summary.sessionId else { return }
    guard appliedScenarioRawValue != scenario else { return }

    let baseScenario = HarnessMonitorUITestEnvironment.basePerfScenario(for: scenario)
    switch baseScenario {
    case "session-search-full":
      guard trigger.hasSearchCorpus else { return }
      appliedScenarioRawValue = scenario
      recordScriptBegin(baseScenario: baseScenario, sessionID: sessionID)
      await runFullSessionSearchScript()
    case "sidebar-toggle-rich-detail":
      guard !trigger.sidebarToggleTargets.isEmpty else { return }
      appliedScenarioRawValue = scenario
      recordScriptBegin(baseScenario: baseScenario, sessionID: sessionID)
      await runSidebarToggleRichDetailScript(targets: trigger.sidebarToggleTargets)
    case "policy-canvas":
      appliedScenarioRawValue = scenario
      recordScriptBegin(baseScenario: baseScenario, sessionID: sessionID)
      await runMeasuredStep(
        "route.policy-canvas",
        details: ["base_scenario": baseScenario]
      ) {
        stateCache.selectRoute(.policyCanvas)
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(180))
      }
    case "timeline-burst", "timeline-filter-form":
      appliedScenarioRawValue = scenario
      recordScriptBegin(baseScenario: baseScenario, sessionID: sessionID)
      await runMeasuredStep(
        "route.timeline",
        details: ["base_scenario": baseScenario]
      ) {
        stateCache.selectRoute(.timeline)
      }
    default:
      return
    }

    HarnessMonitorPerfTrace.recordScenarioEvent(
      event: "script.complete",
      details: [
        "base_scenario": baseScenario,
        "session_id": sessionID,
      ]
    )
  }

  private func recordScriptBegin(baseScenario: String, sessionID: String) {
    HarnessMonitorPerfTrace.recordScenarioEvent(
      event: "script.begin",
      details: [
        "base_scenario": baseScenario,
        "session_id": sessionID,
      ]
    )
  }

  private func runFullSessionSearchScript() async {
    await runMeasuredStep("route.agents") {
      stateCache.selectRoute(.agents)
    }
    await runMeasuredStep("search.present") {
      stateCache.appSearchAutomation.present(query: "")
      await Task.yield()
      try? await Task.sleep(for: .milliseconds(240))
    }

    for step in searchSteps {
      await runMeasuredStep("route.\(step.route.rawValue)") {
        stateCache.selectRoute(step.route)
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(80))
      }
      await runMeasuredStep(
        "query.\(step.query)",
        details: ["route": step.route.rawValue]
      ) {
        stateCache.appSearchAutomation.present(query: step.query)
        try? await Task.sleep(for: .milliseconds(260))
      }
    }

    await runMeasuredStep("search.dismiss") {
      stateCache.appSearchAutomation.dismiss()
    }
  }

  private var searchSteps: [(query: String, route: SessionWindowRoute)] {
    [
      ("worker", .agents),
      ("routing", .tasks),
      ("permission", .decisions),
      ("signal", .timeline),
      ("worker", .agents),
    ]
  }

  private func runSidebarToggleRichDetailScript(
    targets: [SessionSidebarToggleTarget]
  ) async {
    defer { contentDetailDividerWidth = nil }
    await runMeasuredStep("column.double-column") {
      columnVisibility = .doubleColumn
      await Task.yield()
      try? await Task.sleep(for: .milliseconds(180))
    }

    for target in targets {
      await runMeasuredStep(target.selectionStep) {
        selectSidebarToggleTarget(target)
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(180))
      }
      await runMeasuredStep("column.detail-only") {
        columnVisibility = .detailOnly
        try? await Task.sleep(for: .milliseconds(180))
      }
      await runMeasuredStep("column.double-column") {
        columnVisibility = .doubleColumn
      }
      if target.supportsContentDetailDivider {
        await driveContentDetailDividerSweep()
      }
      try? await Task.sleep(for: .milliseconds(220))
    }
  }

  private func driveContentDetailDividerSweep() async {
    let widths: [(String, Double)] = [
      (
        "divider.narrow",
        max(
          contentDetailBaseWidth - 120,
          Double(SessionContentDetailSplitLayout.minimumContentWidth)
        )
      ),
      ("divider.wide", contentDetailBaseWidth + 140),
      ("divider.restore", contentDetailBaseWidth),
    ]

    for (step, width) in widths {
      await runMeasuredStep(
        step,
        details: ["requested_width": String(Int(width.rounded()))]
      ) {
        contentDetailDividerWidth = width
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(180))
      }
    }

    contentDetailDividerWidth = nil
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

  private func selectSidebarToggleTarget(_ target: SessionSidebarToggleTarget) {
    switch target {
    case .agent(let agentID):
      stateCache.selectAgent(agentID)
    case .task(let taskID):
      stateCache.selectTask(taskID)
    case .decision(let decisionID):
      stateCache.selectDecision(decisionID)
    case .route(let route):
      stateCache.selectRoute(route)
    }
  }
}

private enum SessionSidebarToggleTarget: Equatable {
  case agent(String)
  case task(String)
  case decision(String)
  case route(SessionWindowRoute)

  var selectionStep: String {
    switch self {
    case .agent:
      "selection.agent"
    case .task:
      "selection.task"
    case .decision:
      "selection.decision"
    case .route(let route):
      "selection.route.\(route.rawValue)"
    }
  }

  var supportsContentDetailDivider: Bool {
    switch self {
    case .agent, .task, .decision:
      true
    case .route:
      false
    }
  }
}
