import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import Observation
import SwiftUI

/// Per-node verdict derived from `TaskBoardPolicyPipelineSimulationResult`.
/// The decisions array carries `visitedNodeIds` per simulated action, and the
/// terminal decision's `decision` string tells us how that branch ended.
/// Nodes outside any decision's visited set are `.unreached`. When no
/// simulation has run (or the simulation failed end-to-end) the map is empty
/// and the canvas renders without overlays.
///
/// Three real verdicts only: allowed, denied, unreached. A decision string
/// the daemon emits but we don't know how to classify is a parse failure,
/// not a verdict; we model that as "no entry in the map" (i.e. absence),
/// keeping the enum free of an "unknown classification" case that conflated
/// two concepts in earlier revisions.
enum PolicyCanvasSimulationOutcome: Equatable {
  /// Visited by a decision branch that terminated with `decision == "allow"`.
  case allowed
  /// Visited by a decision branch that terminated with `decision == "deny"`
  /// or `decision == "require_human"`. The associated reason is the daemon's
  /// `reasonCode`, surfaced in the badge tooltip and a11y label.
  case denied(reason: String)
  /// Reachable in the document but never visited by any simulated decision.
  /// Rendered as a 50% opacity dim overlay so dead branches stay visually
  /// quiet but remain legible for the user.
  case unreached
}

/// Cached output of `derivePerNodeOutcomes`. Mirrors the Wave 2E severity-map
/// cache layout in `+ValidationCache.swift`: token + stored map, so cache
/// writes are a single assignment to the `@ObservationIgnored` slot.
struct PolicyCanvasSimulationOutcomeCacheEntry {
  let token: PolicyCanvasViewModel.SimulationOutcomeCacheToken
  let map: [String: PolicyCanvasSimulationOutcome]
}

extension PolicyCanvasViewModel {
  /// Snapshot of the inputs that drive per-node outcomes. Two reads with the
  /// same token must yield the same `[nodeID: outcome]` map. Hashable on
  /// `(simulation revision, simulation success, decisions count, node count)`.
  /// Same precedent as `ValidationCacheToken` in `+ValidationCache.swift`.
  struct SimulationOutcomeCacheToken: Hashable {
    let simulationRevision: UInt64?
    let simulationSucceeded: Bool
    let decisionCount: Int
    let nodeCount: Int
  }

  /// Token for the current outcome map. Changes only when `latestSimulation`
  /// changes (revision, success, decisions) or the node set changes; selection
  /// flips and unrelated mutations don't touch it.
  func simulationOutcomeCacheToken() -> SimulationOutcomeCacheToken {
    SimulationOutcomeCacheToken(
      simulationRevision: latestSimulation?.revision,
      simulationSucceeded: latestSimulation?.succeeded ?? false,
      decisionCount: latestSimulation?.decisions.count ?? 0,
      nodeCount: nodes.count
    )
  }

  /// Returns the per-node outcome map for the latest simulation, rebuilding
  /// when the cache token misses. Empty when `latestSimulation` is nil or
  /// `succeeded == false`. Hot-path callers (the overlay layer body) must
  /// hoist this into a body-local `let` so per-row lookups stay O(1) and
  /// don't compare the token on every iteration.
  ///
  /// Mirrors the Wave 2E severity-map cache: a single `@ObservationIgnored`
  /// storage slot keyed on a coarse hashable token. The storage is
  /// observation-ignored deliberately — if SwiftUI tracked it, every body
  /// that reads the map would re-run on the same body's cache write and the
  /// cache would defeat itself.
  func simulationOutcomeMap() -> [String: PolicyCanvasSimulationOutcome] {
    let token = simulationOutcomeCacheToken()
    if let cached = simulationOutcomeCacheStorage, cached.token == token {
      return cached.map
    }
    let map = derivePerNodeOutcomes()
    simulationOutcomeCacheStorage = PolicyCanvasSimulationOutcomeCacheEntry(
      token: token,
      map: map
    )
    return map
  }

  /// Walk `latestSimulation.decisions` and project a per-node outcome.
  ///
  /// Mapping rules:
  ///   1. The last `visitedNodeIds` entry of a decision is the terminal node
  ///      for that branch; it carries the decision's verdict.
  ///   2. Earlier visited nodes carry the same verdict — the simulation
  ///      reached them on the way to the terminal.
  ///   3. When a node appears in multiple decisions with mismatched verdicts
  ///      the dominance rule is `denied > allowed`. A node with no decision
  ///      mention is absent from the map (no opinion to express).
  ///   4. Nodes that exist in `nodes` but never appear in any classifiable
  ///      decision's `visitedNodeIds` are `.unreached` — the simulation
  ///      succeeded but this branch was dead from the start.
  ///   5. Decision strings the daemon emits but we cannot classify
  ///      (anything other than `allow` / `deny` / `require_human`) are a
  ///      parse failure, not a verdict. We leave their visited nodes out of
  ///      the map entirely; the overlay renders no badge for them.
  ///   6. When `succeeded == false` or there are no decisions, we return an
  ///      empty map. Drawing badges on a failed sim would mislead.
  func derivePerNodeOutcomes() -> [String: PolicyCanvasSimulationOutcome] {
    guard let simulation = latestSimulation, simulation.succeeded else {
      return [:]
    }
    guard !simulation.decisions.isEmpty else {
      return [:]
    }
    var outcomes: [String: PolicyCanvasSimulationOutcome] = [:]
    var classifiedAny = false
    for decision in simulation.decisions {
      guard let verdict = outcome(for: decision.decision) else {
        // Unclassifiable verdict string — leave visited nodes absent.
        continue
      }
      classifiedAny = true
      for nodeID in decision.visitedNodeIds {
        outcomes[nodeID] = preferred(existing: outcomes[nodeID], incoming: verdict)
      }
    }
    guard classifiedAny else {
      // No classifiable decisions at all — render no overlays.
      return [:]
    }
    let documentNodeIDs = Set(nodes.map(\.id))
    for nodeID in documentNodeIDs where outcomes[nodeID] == nil {
      outcomes[nodeID] = .unreached
    }
    return outcomes
  }

  /// Classify a terminal decision string into the canvas verdict.
  /// `"allow"` → `.allowed`, `"deny"` and `"require_human"` →
  /// `.denied(reason)`, anything else → `nil` (absent from the outcome map).
  /// The daemon emits these strings; until it ships a typed enum (P11 shim
  /// territory) we map here. Returning `nil` for unrecognized strings keeps
  /// "we don't know how to classify" out of the verdict enum.
  private func outcome(
    for decision: TaskBoardPolicyDecision
  ) -> PolicyCanvasSimulationOutcome? {
    switch decision.decision {
    case "allow":
      return .allowed
    case "deny", "require_human":
      return .denied(reason: decision.reasonCode)
    default:
      return nil
    }
  }

  /// Choose the more informative outcome when a node appears in two
  /// decisions. Dominance: denied > allowed. `.unreached` never appears
  /// here — it's a fill-in for nodes absent from every classifiable
  /// decision and is applied after the per-decision walk.
  private func preferred(
    existing: PolicyCanvasSimulationOutcome?,
    incoming: PolicyCanvasSimulationOutcome
  ) -> PolicyCanvasSimulationOutcome {
    guard let existing else {
      return incoming
    }
    // Denied dominates allowed; otherwise keep the first seen.
    if case .denied = existing {
      return existing
    }
    if case .denied = incoming {
      return incoming
    }
    return existing
  }
}
