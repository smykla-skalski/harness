import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

/// Drift guard: the canvas node-kind palette must cover exactly the Rust
/// `POLICY_NODE_KIND_DESCRIPTORS` catalog, with matching categories. Adding a
/// node kind on one side without the other fails here, keeping the node-kind
/// descriptor registry a single source of truth across both runtimes.
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
}
