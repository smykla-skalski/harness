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

    switch HarnessMonitorUITestEnvironment.basePerfScenario(for: scenario) {
    case "session-search-full":
      guard trigger.hasSearchCorpus else { return }
      appliedScenarioRawValue = scenario
      await runFullSessionSearchScript()
    case "sidebar-toggle-rich-detail":
      guard !trigger.sidebarToggleTargets.isEmpty else { return }
      appliedScenarioRawValue = scenario
      await runSidebarToggleRichDetailScript(targets: trigger.sidebarToggleTargets)
    case "timeline-burst", "timeline-filter-form":
      appliedScenarioRawValue = scenario
      stateCache.selectRoute(.timeline)
    default:
      return
    }
  }

  private func runFullSessionSearchScript() async {
    stateCache.selectRoute(.agents)
    stateCache.appSearchAutomation.present(query: "")
    await Task.yield()
    try? await Task.sleep(for: .milliseconds(240))

    for step in searchSteps {
      stateCache.selectRoute(step.route)
      await Task.yield()
      try? await Task.sleep(for: .milliseconds(80))
      stateCache.appSearchAutomation.present(query: step.query)
      try? await Task.sleep(for: .milliseconds(260))
    }

    stateCache.appSearchAutomation.dismiss()
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
    columnVisibility = .doubleColumn
    await Task.yield()
    try? await Task.sleep(for: .milliseconds(180))

    for target in targets {
      selectSidebarToggleTarget(target)
      await Task.yield()
      try? await Task.sleep(for: .milliseconds(180))
      columnVisibility = .detailOnly
      try? await Task.sleep(for: .milliseconds(180))
      columnVisibility = .doubleColumn
      try? await Task.sleep(for: .milliseconds(220))
    }
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
}
