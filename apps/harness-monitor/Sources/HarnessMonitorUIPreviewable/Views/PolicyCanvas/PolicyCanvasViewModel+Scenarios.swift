import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import HarnessMonitorPolicyModels

/// One row of the scenario inspector: a named confidence scenario and how the
/// current draft resolves it under the latest simulation. Identifiable by the
/// scenario id, with a name+action fallback for decisions a pre-scenario daemon
/// emitted without one. Carries only value types so the inspector never reaches
/// into the wire model.
struct PolicyCanvasScenarioRowModel: Identifiable, Equatable {
  let id: String
  let name: String
  let actionTitle: String
  let verdict: PolicyCanvasDecisionVerdict
  let reasonCode: String
  let visitedNodeIds: [String]
}

extension PolicyCanvasViewModel {
  /// Scenario rows projected from the latest simulation. Post-Phase-4 the daemon
  /// simulates one decision per workspace scenario, each carrying its scenario id
  /// and name, so the inspector reads the live scenario set straight off the
  /// simulation. Empty when no simulation has run or it failed end-to-end (the
  /// validation panel carries the errors in that case).
  var scenarioRows: [PolicyCanvasScenarioRowModel] {
    guard let simulation = latestSimulation, simulation.succeeded else {
      return []
    }
    return simulation.decisions.map { decision in
      let resolvedId =
        decision.scenarioId.isEmpty
        ? "\(decision.scenarioName)|\(decision.action.rawValue)"
        : decision.scenarioId
      let resolvedName =
        decision.scenarioName.isEmpty
        ? decision.action.policyCanvasTitle
        : decision.scenarioName
      return PolicyCanvasScenarioRowModel(
        id: resolvedId,
        name: resolvedName,
        actionTitle: decision.action.policyCanvasTitle,
        verdict: PolicyCanvasDecisionVerdict(decisionString: decision.decision.decision),
        reasonCode: decision.decision.reasonCode,
        visitedNodeIds: decision.visitedNodeIds
      )
    }
  }
}
