import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

/// Drift guard: the canvas node-kind palette must cover exactly the Rust
/// `POLICY_NODE_KIND_DESCRIPTORS` catalog, with matching categories and
/// template ports. Adding a node kind (or changing its ports) on one side
/// without the other fails here, keeping the node-kind descriptor registry a
/// single source of truth across both runtimes.
@Suite("Policy canvas node-kind catalog")
struct PolicyCanvasNodeKindCatalogTests {
  /// Mirrors `src/task_board/policy_graph/node_kinds.rs`
  /// `POLICY_NODE_KIND_DESCRIPTORS` (id -> category).
  private static let canonicalCategoriesByID: [String: String] = [
    "trigger": "source",
    "workflow_entry": "source",
    "action_gate": "condition",
    "evidence_check": "condition",
    "risk_classifier": "condition",
    "human_gate": "review",
    "consensus_gate": "review",
    "action_step": "transform",
    "wait_step": "transform",
    "event_wait": "transform",
    "handoff": "transform",
    "dry_run_gate": "decision",
    "supervisor_rule": "decision",
    "finish": "decision",
  ]

  /// Mirrors `src/task_board/policy_graph/node_kinds.rs`
  /// `POLICY_NODE_KIND_DESCRIPTORS` (id -> template input/output ports).
  private static let canonicalPortsByID: [String: (input: [String], output: [String])] = [
    "trigger": ([], ["event"]),
    "workflow_entry": ([], ["out"]),
    "action_gate": (["in"], ["match", "default"]),
    "evidence_check": (["in"], ["pass", "fail", "missing"]),
    "risk_classifier": (["in"], ["low_or_equal", "high", "missing"]),
    "human_gate": (["in"], []),
    "consensus_gate": (["in"], []),
    "action_step": (["in"], ["out"]),
    "wait_step": (["in"], ["out"]),
    "event_wait": (["in"], ["out"]),
    "handoff": (["in"], ["out"]),
    "dry_run_gate": (["in"], []),
    "supervisor_rule": (["in"], []),
    "finish": (["in"], []),
  ]

  @Test("palette covers exactly the Rust node-kind catalog ids")
  func paletteCoversCatalogIDs() {
    let paletteIDs = Set(PolicyCanvasNodeKind.allCases.map(\.rawValue))
    #expect(paletteIDs == Set(Self.canonicalCategoriesByID.keys))
  }

  @Test("each palette kind carries the catalog category")
  func paletteCategoriesMatchCatalog() {
    for kind in PolicyCanvasNodeKind.allCases {
      #expect(
        Self.canonicalCategoriesByID[kind.rawValue] == kind.category.rawValue,
        "category drift for node kind \(kind.rawValue)"
      )
    }
  }

  @Test("palette ports cover exactly the Rust node-kind catalog ids")
  func palettePortsCoverCatalogIDs() {
    let paletteIDs = Set(PolicyCanvasNodeKind.allCases.map(\.rawValue))
    #expect(paletteIDs == Set(Self.canonicalPortsByID.keys))
  }

  @Test("each palette kind carries the catalog template ports")
  func palettePortsMatchCatalog() {
    for kind in PolicyCanvasNodeKind.allCases {
      guard let canonical = Self.canonicalPortsByID[kind.rawValue] else {
        Issue.record("no canonical ports for node kind \(kind.rawValue)")
        continue
      }
      #expect(
        kind.inputPortTitles == canonical.input,
        "input-port drift for node kind \(kind.rawValue)"
      )
      #expect(
        kind.outputPortTitles == canonical.output,
        "output-port drift for node kind \(kind.rawValue)"
      )
    }
  }
}
