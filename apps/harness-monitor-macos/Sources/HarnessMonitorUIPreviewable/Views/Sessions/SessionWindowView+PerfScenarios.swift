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
}

struct SessionWindowPerfScenarioScript: ViewModifier {
  let stateCache: SessionWindowStateCache
  let sessionID: String
  let snapshot: HarnessMonitorSessionWindowSnapshot?

  @State private var appliedScenarioRawValue: String?

  private var trigger: SessionWindowPerfScenarioTrigger {
    SessionWindowPerfScenarioTrigger(
      rawValue: HarnessMonitorUITestEnvironment.perfScenarioRawValue,
      sessionID: sessionID,
      hasSearchCorpus: hasSearchCorpus
    )
  }

  private var hasSearchCorpus: Bool {
    guard let snapshot, let detail = snapshot.detail else {
      return false
    }
    return !detail.agents.isEmpty || !detail.tasks.isEmpty || !snapshot.timeline.isEmpty
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
}
