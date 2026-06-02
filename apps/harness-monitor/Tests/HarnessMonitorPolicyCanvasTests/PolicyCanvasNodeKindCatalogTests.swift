import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas

/// Drift guard: the canvas node-kind catalog must cover exactly the Rust
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
    "if_then_else": "condition",
    "switch": "condition",
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
    "if_then_else": (["in"], ["then", "else"]),
    "switch": (["in"], ["case_1", "default"]),
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

  @Test("catalog covers exactly the Rust node-kind ids")
  func catalogCoversIDs() {
    let catalogIDs = Set(PolicyCanvasNodeKind.allCases.map(\.rawValue))
    #expect(catalogIDs == Set(Self.canonicalCategoriesByID.keys))
  }

  @Test("each catalog kind carries the Rust category")
  func catalogCategoriesMatchRust() {
    for kind in PolicyCanvasNodeKind.allCases {
      #expect(
        Self.canonicalCategoriesByID[kind.rawValue] == kind.category.rawValue,
        "category drift for node kind \(kind.rawValue)"
      )
    }
  }

  @Test("catalog ports cover exactly the Rust node-kind ids")
  func catalogPortsCoverIDs() {
    let catalogIDs = Set(PolicyCanvasNodeKind.allCases.map(\.rawValue))
    #expect(catalogIDs == Set(Self.canonicalPortsByID.keys))
  }

  @Test("each catalog kind carries the Rust template ports")
  func catalogPortsMatchRust() {
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

  @Test("authoring cases expose the generic condition builders")
  func authoringCasesExposeGenericConditionBuilders() {
    let authoringIDs = PolicyCanvasNodeKind.authoringCases().map(\.rawValue)
    let conditionIDs = PolicyCanvasNodeKind.authoringCases()
      .filter { $0.librarySection == .conditions }
      .map(\.rawValue)

    #expect(authoringIDs.contains("if_then_else"))
    #expect(authoringIDs.contains("switch"))
    #expect(conditionIDs == ["if_then_else", "switch"])
    #expect(!authoringIDs.contains("action_gate"))
    #expect(!authoringIDs.contains("evidence_check"))
    #expect(!authoringIDs.contains("risk_classifier"))
  }

  @Test("authoring cases keep a loaded legacy condition selectable")
  func authoringCasesKeepLoadedLegacyConditionSelectable() {
    let legacyIDs = PolicyCanvasNodeKind.authoringCases(including: .riskClassifier).map(\.rawValue)
    let canonicalIDs = PolicyCanvasNodeKind.authoringCases(including: .ifThenElse).map(\.rawValue)

    #expect(legacyIDs.contains("if_then_else"))
    #expect(legacyIDs.contains("switch"))
    #expect(legacyIDs.last == "risk_classifier")
    #expect(legacyIDs.filter { $0 == "risk_classifier" }.count == 1)
    #expect(!canonicalIDs.contains("risk_classifier"))
  }

  @Test("if then else metadata stays visually distinct from legacy evidence checks")
  func ifThenElseMetadataIsDistinct() {
    let kind = PolicyCanvasNodeKind(rawValue: "if_then_else")
    #expect(kind != nil)
    guard let kind else { return }
    #expect(kind.symbolName == "diamond")
    #expect(kind.outputPortTitles == ["then", "else"])
    #expect(
      kind.accentColor.description != PolicyCanvasNodeKind.evidenceCheck.accentColor.description
    )
  }

  @Test("switch metadata stays distinct from if then else")
  func switchMetadataIsDistinct() {
    let kind = PolicyCanvasNodeKind(rawValue: "switch")
    #expect(kind != nil)
    guard let kind else { return }
    #expect(kind.symbolName != PolicyCanvasNodeKind.ifThenElse.symbolName)
    #expect(kind.outputPortTitles == ["case_1", "default"])
    #expect(kind.librarySubtitle != PolicyCanvasNodeKind.ifThenElse.librarySubtitle)
  }
}
