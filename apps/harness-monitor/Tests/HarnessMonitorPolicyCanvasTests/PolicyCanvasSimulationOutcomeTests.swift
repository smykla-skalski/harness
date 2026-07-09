import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

/// Covers the per-node simulation-outcome map that feeds the canvas
/// simulation overlay. Two contracts matter:
///   1. The derivation maps `PolicyPipelineSimulatedDecision`
///      visited node ids onto allowed / denied / unreached, with denied
///      dominating allowed when a node appears in mismatched decisions.
///      Unclassifiable verdict strings leave their visited nodes absent
///      from the map (no badge rendered).
///   2. The cache uses an `@ObservationIgnored` storage slot keyed on a
///      simulation-shape token, so unrelated mutations (selection, drag
///      ticks) do not invalidate it.
@Suite("Policy canvas simulation outcome")
@MainActor
struct PolicyCanvasSimulationOutcomeTests {
  @Test("allow decision marks every visited node as allowed")
  func allowedNodes() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.latestSimulation = makeSimulation(
      succeeded: true,
      decisions: [
        decision(
          verdict: "allow",
          reasonCode: "default_allow",
          visited: ["policy-source", "risk-score", "context-map", "promote-release"]
        )
      ]
    )

    let map = viewModel.simulationOutcomeMap()

    #expect(map["policy-source"] == .allowed)
    #expect(map["risk-score"] == .allowed)
    #expect(map["context-map"] == .allowed)
    #expect(map["promote-release"] == .allowed)
  }

  @Test("deny decision threads the daemon reason code through .denied")
  func deniedCarriesReason() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.latestSimulation = makeSimulation(
      succeeded: true,
      decisions: [
        decision(
          verdict: "deny",
          reasonCode: "merge_risk_high",
          visited: ["policy-source", "risk-score", "review-gate"]
        )
      ]
    )

    let map = viewModel.simulationOutcomeMap()

    if case .denied(let reason) = map["review-gate"] {
      #expect(reason == "merge_risk_high")
    } else {
      Issue.record("expected review-gate to be denied with merge_risk_high")
    }
    // Every visited node carries the verdict.
    guard case .denied = map["risk-score"] else {
      Issue.record("expected risk-score to also be denied")
      return
    }
  }

  @Test("require_human verdict surfaces as denied(reason)")
  func requireHumanIsDenied() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.latestSimulation = makeSimulation(
      succeeded: true,
      decisions: [
        decision(
          verdict: "require_human",
          reasonCode: "human_required",
          visited: ["policy-source", "review-gate"]
        )
      ]
    )

    let map = viewModel.simulationOutcomeMap()

    if case .denied(let reason) = map["review-gate"] {
      #expect(reason == "human_required")
    } else {
      Issue.record("expected review-gate to be denied with human_required")
    }
  }

  @Test("denied dominates allowed when a node appears in mismatched decisions")
  func deniedDominatesAllowed() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.latestSimulation = makeSimulation(
      succeeded: true,
      decisions: [
        decision(
          verdict: "allow",
          reasonCode: "default_allow",
          visited: ["policy-source", "context-map"]
        ),
        decision(
          verdict: "deny",
          reasonCode: "merge_risk_high",
          visited: ["policy-source", "risk-score"]
        ),
      ]
    )

    let map = viewModel.simulationOutcomeMap()

    guard case .denied = map["policy-source"] else {
      Issue.record("policy-source visited by both verdicts must end up denied")
      return
    }
    #expect(map["context-map"] == .allowed)
    guard case .denied = map["risk-score"] else {
      Issue.record("risk-score must be denied")
      return
    }
  }

  @Test("denied dominates allowed regardless of decision order")
  func deniedDominatesAllowedReverseOrder() {
    let viewModel = PolicyCanvasViewModel.sample()
    // Same as deniedDominatesAllowed but deny first, allow second — the
    // dominance rule must be insensitive to decision order.
    viewModel.latestSimulation = makeSimulation(
      succeeded: true,
      decisions: [
        decision(
          verdict: "deny",
          reasonCode: "merge_risk_high",
          visited: ["policy-source", "risk-score"]
        ),
        decision(
          verdict: "allow",
          reasonCode: "default_allow",
          visited: ["policy-source", "context-map"]
        ),
      ]
    )

    let map = viewModel.simulationOutcomeMap()

    guard case .denied = map["policy-source"] else {
      Issue.record("policy-source must stay denied even when allow lands second")
      return
    }
  }

  @Test("nodes never visited by any decision are reported as unreached")
  func unreachedFillsInUnvisitedNodes() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.latestSimulation = makeSimulation(
      succeeded: true,
      decisions: [
        decision(
          verdict: "allow",
          reasonCode: "default_allow",
          visited: ["policy-source", "risk-score"]
        )
      ]
    )

    let map = viewModel.simulationOutcomeMap()

    // context-map, review-gate, promote-release exist in sample data but
    // aren't in any decision's visited list — they must be .unreached.
    #expect(map["context-map"] == .unreached)
    #expect(map["review-gate"] == .unreached)
    #expect(map["promote-release"] == .unreached)
  }

  @Test("unknown decision string leaves visited nodes absent from the map")
  func unknownDecisionIsAbsent() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.latestSimulation = makeSimulation(
      succeeded: true,
      decisions: [
        decision(
          verdict: "defer",
          reasonCode: "defer_to_next",
          visited: ["review-gate"]
        )
      ]
    )

    let map = viewModel.simulationOutcomeMap()

    // The visited node is absent from the map (no entry, no badge).
    #expect(map["review-gate"] == nil)
    // No classifiable decisions at all — the entire map is empty;
    // sibling nodes do NOT get an .unreached fill-in.
    #expect(map.isEmpty)
  }

  @Test("classifiable decision alongside unknown lets unknown stay absent")
  func unknownDecisionAlongsideClassifiableIsAbsent() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.latestSimulation = makeSimulation(
      succeeded: true,
      decisions: [
        decision(
          verdict: "allow",
          reasonCode: "default_allow",
          visited: ["policy-source", "risk-score"]
        ),
        decision(
          verdict: "defer",
          reasonCode: "defer_to_next",
          visited: ["review-gate"]
        ),
      ]
    )

    let map = viewModel.simulationOutcomeMap()

    #expect(map["policy-source"] == .allowed)
    #expect(map["risk-score"] == .allowed)
    // The unknown ("defer") decision didn't seed review-gate. Because at
    // least one classifiable decision exists, the unreached fill-in
    // marks every document node not seeded by a classifiable decision —
    // including review-gate.
    #expect(map["review-gate"] == .unreached)
    #expect(map["context-map"] == .unreached)
  }

  @Test("nil simulation yields an empty map with no errors")
  func nilSimulationIsEmpty() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.latestSimulation = nil

    let map = viewModel.simulationOutcomeMap()

    #expect(map.isEmpty)
  }

  @Test("failed simulation (succeeded=false) yields an empty map")
  func failedSimulationIsEmpty() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.latestSimulation = makeSimulation(
      succeeded: false,
      decisions: [
        decision(
          verdict: "allow",
          reasonCode: "default_allow",
          visited: ["policy-source"]
        )
      ]
    )

    let map = viewModel.simulationOutcomeMap()

    #expect(map.isEmpty)
  }

  @Test("repeated reads reuse the cached storage without rebuilding")
  func cacheReusesAcrossReads() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.latestSimulation = makeSimulation(
      succeeded: true,
      decisions: [
        decision(
          verdict: "allow",
          reasonCode: "default_allow",
          visited: ["policy-source", "risk-score"]
        )
      ]
    )

    #expect(viewModel.simulationOutcomeCacheStorage == nil)
    let first = viewModel.simulationOutcomeMap()
    let primedToken = viewModel.simulationOutcomeCacheStorage?.token
    #expect(primedToken != nil)

    let second = viewModel.simulationOutcomeMap()

    #expect(first == second)
    #expect(viewModel.simulationOutcomeCacheStorage?.token == primedToken)
  }

  @Test("cache invalidates when latestSimulation is reassigned")
  func cacheInvalidatesOnSimulationAssign() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.latestSimulation = makeSimulation(
      succeeded: true,
      decisions: [
        decision(
          verdict: "allow",
          reasonCode: "default_allow",
          visited: ["policy-source"]
        )
      ]
    )
    let first = viewModel.simulationOutcomeMap()
    #expect(first["policy-source"] == .allowed)

    viewModel.latestSimulation = makeSimulation(
      revision: 7,
      succeeded: true,
      decisions: [
        decision(
          verdict: "deny",
          reasonCode: "blocked",
          visited: ["policy-source"]
        )
      ]
    )

    let second = viewModel.simulationOutcomeMap()
    if case .denied(let reason) = second["policy-source"] {
      #expect(reason == "blocked")
    } else {
      Issue.record("cache must rebuild on simulation reassign")
    }
  }

  @Test("cache does not rebuild when only selection changes")
  func selectionChangeDoesNotInvalidateCache() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.latestSimulation = makeSimulation(
      succeeded: true,
      decisions: [
        decision(
          verdict: "allow",
          reasonCode: "default_allow",
          visited: ["policy-source"]
        )
      ]
    )
    _ = viewModel.simulationOutcomeMap()
    let tokenBefore = viewModel.simulationOutcomeCacheStorage?.token

    viewModel.select(.node("risk-score"))
    _ = viewModel.simulationOutcomeMap()
    let tokenAfter = viewModel.simulationOutcomeCacheStorage?.token

    #expect(tokenBefore == tokenAfter)
  }

  @Test("token differs when simulation revision changes")
  func tokenDiffersOnRevisionChange() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.latestSimulation = makeSimulation(revision: 1, succeeded: true)
    let firstToken = viewModel.simulationOutcomeCacheToken()

    viewModel.latestSimulation = makeSimulation(revision: 2, succeeded: true)
    let secondToken = viewModel.simulationOutcomeCacheToken()

    #expect(firstToken != secondToken)
  }

  // MARK: - Helpers

  private func makeSimulation(
    revision: UInt64 = 1,
    succeeded: Bool,
    decisions: [PolicyPipelineSimulatedDecision] = []
  ) -> PolicyPipelineSimulationResult {
    PolicyPipelineSimulationResult(
      revision: revision,
      traceId: "trace-test-\(revision)",
      simulatedAt: "2026-05-14T00:00:00Z",
      succeeded: succeeded,
      validation: PolicyPipelineValidation(isValid: succeeded),
      decisions: decisions
    )
  }

  private func decision(
    verdict: String,
    reasonCode: String,
    visited: [String]
  ) -> PolicyPipelineSimulatedDecision {
    PolicyPipelineSimulatedDecision(
      action: .mergePr,
      decision: PolicySimulationDecision(
        decision: verdict,
        reasonCode: reasonCode,
        policyVersion: "test-policy"
      ),
      visitedNodeIds: visited
    )
  }
}
