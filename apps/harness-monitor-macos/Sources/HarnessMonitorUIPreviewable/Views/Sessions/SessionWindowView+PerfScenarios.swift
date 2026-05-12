import HarnessMonitorKit
import SwiftUI

private struct SessionWindowPerfScenarioTrigger: Equatable {
  let rawValue: String?
  let sessionID: String
  let hasDetail: Bool
  let decisionCount: Int
}

private enum SessionWindowPerfScenarioRouteScript {
  private static let visualOptionsSuffix = "-visual-options-disabled"

  static func baseScenario(for rawValue: String) -> String {
    guard rawValue.hasSuffix(visualOptionsSuffix) else {
      return rawValue
    }
    return String(rawValue.dropLast(visualOptionsSuffix.count))
  }
}

struct SessionWindowPerfScenarioScript: ViewModifier {
  let stateCache: SessionWindowStateCache
  let store: HarnessMonitorStore
  let sessionID: String
  let snapshot: HarnessMonitorSessionWindowSnapshot?

  @State private var appliedScenarioRawValue: String?

  private var trigger: SessionWindowPerfScenarioTrigger {
    SessionWindowPerfScenarioTrigger(
      rawValue: HarnessMonitorUITestEnvironment.perfScenarioRawValue,
      sessionID: sessionID,
      hasDetail: snapshot?.detail != nil,
      decisionCount: store.supervisorOpenDecisions.count
    )
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

    switch SessionWindowPerfScenarioRouteScript.baseScenario(for: scenario) {
    case "session-search-full":
      guard trigger.hasDetail, trigger.decisionCount > 0 else { return }
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
    stateCache.appSearchModel.setPresented(true)
    await Task.yield()
    try? await Task.sleep(for: .milliseconds(120))

    for step in searchSteps {
      await stateCache.appSearchModel.runSearch(query: step.query, primary: step.primary)
      try? await Task.sleep(for: .milliseconds(80))
    }
  }

  private var searchSteps: [(query: String, primary: AppSearchDomain?)] {
    [
      ("worker", .agents),
      ("routing", .tasks),
      ("permission", .decisions),
      ("signal", .timeline),
      ("worker", .agents),
    ]
  }
}
