import HarnessMonitorKit
import Observation
import SwiftUI

/// Per-node verdict derived from `TaskBoardPolicyPipelineSimulationResult`.
/// The decisions array carries `visitedNodeIds` per simulated action, and the
/// terminal decision's `decision` string tells us how that branch ended.
/// Nodes outside any decision's visited set are `.unreached`. When no
/// simulation has run (or the simulation failed end-to-end) the map is empty
/// and the canvas renders without overlays.
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
  /// Visited but the decision branch terminated with a value we cannot
  /// classify. No badge is drawn — silence beats lying.
  case indeterminate
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
  ///      we keep the most informative one in this order: denied > allowed >
  ///      indeterminate. Denied dominates because a deny anywhere along a
  ///      node's lineage is the signal a user most cares about.
  ///   4. Nodes that exist in `nodes` but never appear in any decision's
  ///      `visitedNodeIds` are `.unreached` — the simulation succeeded but
  ///      this branch was dead from the start.
  ///   5. When `succeeded == false` or there are no decisions, we return an
  ///      empty map. Drawing badges on a failed sim would mislead.
  func derivePerNodeOutcomes() -> [String: PolicyCanvasSimulationOutcome] {
    guard let simulation = latestSimulation, simulation.succeeded else {
      return [:]
    }
    guard !simulation.decisions.isEmpty else {
      return [:]
    }
    var outcomes: [String: PolicyCanvasSimulationOutcome] = [:]
    for decision in simulation.decisions {
      let verdict = outcome(for: decision.decision)
      for nodeID in decision.visitedNodeIds {
        outcomes[nodeID] = preferred(existing: outcomes[nodeID], incoming: verdict)
      }
    }
    let documentNodeIDs = Set(nodes.map(\.id))
    for nodeID in documentNodeIDs where outcomes[nodeID] == nil {
      outcomes[nodeID] = .unreached
    }
    return outcomes
  }

  /// Classify a terminal decision string into the canvas verdict.
  /// `"allow"` → `.allowed`, `"deny"` and `"require_human"` →
  /// `.denied(reason)`, anything else → `.indeterminate`. The daemon emits
  /// these strings; until it ships a typed enum (P11 shim territory) we map
  /// here.
  private func outcome(
    for decision: TaskBoardPolicyDecision
  ) -> PolicyCanvasSimulationOutcome {
    switch decision.decision {
    case "allow":
      return .allowed
    case "deny", "require_human":
      return .denied(reason: decision.reasonCode)
    default:
      return .indeterminate
    }
  }

  /// Choose the more informative outcome when a node appears in two
  /// decisions. Priority: denied > allowed > indeterminate. `.unreached` is
  /// never seeded by `derivePerNodeOutcomes` from this path (it's a fill-in
  /// for nodes absent from every decision), so it doesn't appear here.
  private func preferred(
    existing: PolicyCanvasSimulationOutcome?,
    incoming: PolicyCanvasSimulationOutcome
  ) -> PolicyCanvasSimulationOutcome {
    guard let existing else {
      return incoming
    }
    // Denied dominates everything else.
    if case .denied = existing {
      return existing
    }
    if case .denied = incoming {
      return incoming
    }
    // Allowed beats indeterminate.
    if existing == .allowed {
      return existing
    }
    if incoming == .allowed {
      return incoming
    }
    return existing
  }
}
