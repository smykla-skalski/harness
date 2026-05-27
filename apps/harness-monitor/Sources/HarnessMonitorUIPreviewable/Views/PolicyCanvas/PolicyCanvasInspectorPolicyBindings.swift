import HarnessMonitorKit
import SwiftUI

extension PolicyCanvasEditForm {
  /// Discrete policy-kind options surfaced by the picker. Order matches the
  /// daemon's enum walk: trigger -> action gate -> evidence -> risk -> human
  /// -> consensus -> dry-run -> supervisor. Tag identity is the kind string
  /// so `Picker` does not require `Hashable` on the full
  /// `TaskBoardPolicyPipelineNodeKind` struct (it carries non-Hashable
  /// payloads). `defaultPolicyKind(for:)` rebuilds the full struct with
  /// sensible defaults when the user picks a kind.
  static let policyKindOptions: [String] = [
    "trigger",
    "action_gate",
    "evidence_check",
    "risk_classifier",
    "human_gate",
    "consensus_gate",
    "dry_run_gate",
    "supervisor_rule",
  ]

  static func policyKindTitle(for kind: String) -> String {
    switch kind {
    case "trigger":
      return "Trigger"
    case "action_gate":
      return "Action gate"
    case "evidence_check":
      return "Evidence check"
    case "risk_classifier":
      return "Risk classifier"
    case "human_gate":
      return "Human gate"
    case "consensus_gate":
      return "Consensus gate"
    case "dry_run_gate":
      return "Dry-run gate"
    case "supervisor_rule":
      return "Supervisor rule"
    default:
      return kind.replacingOccurrences(of: "_", with: " ").capitalized
    }
  }

  /// Build a `TaskBoardPolicyPipelineNodeKind` for the given kind string,
  /// preserving as much existing payload as possible. When the user picks
  /// the same kind back, the result is byte-equal to the source; otherwise
  /// the result carries the minimal sensible defaults for the new kind so
  /// the daemon round-trip succeeds without a follow-up edit.
  static func defaultPolicyKind(
    for kindString: String,
    existing: TaskBoardPolicyPipelineNodeKind?
  ) -> TaskBoardPolicyPipelineNodeKind {
    if let existing, existing.kind == kindString {
      return existing
    }
    switch kindString {
    case "trigger":
      return TaskBoardPolicyPipelineNodeKind(kind: "trigger", workflow: "default-task")
    case "action_gate":
      return TaskBoardPolicyPipelineNodeKind(kind: "action_gate", action: .spawnAgent)
    case "evidence_check":
      return TaskBoardPolicyPipelineNodeKind(kind: "evidence_check")
    case "risk_classifier":
      return TaskBoardPolicyPipelineNodeKind(kind: "risk_classifier", threshold: 50)
    case "human_gate":
      return TaskBoardPolicyPipelineNodeKind(kind: "human_gate")
    case "consensus_gate":
      return TaskBoardPolicyPipelineNodeKind(kind: "consensus_gate")
    case "dry_run_gate":
      return TaskBoardPolicyPipelineNodeKind(kind: "dry_run_gate")
    case "supervisor_rule":
      return TaskBoardPolicyPipelineNodeKind(
        kind: "supervisor_rule",
        ruleId: "stuck-agent"
      )
    default:
      return TaskBoardPolicyPipelineNodeKind(kind: kindString)
    }
  }

  func selectedNodePolicyKindStringBinding(
    _ node: PolicyCanvasNode
  ) -> Binding<String> {
    Binding(
      get: {
        node.policyKind?.kind ?? taskBoardPolicyNodeKind(for: node.kind).kind
      },
      set: { newKindString in
        let newKind = Self.defaultPolicyKind(
          for: newKindString,
          existing: node.policyKind
        )
        viewModel.commitSelectedNodePolicyKind(newKind)
      }
    )
  }

  func selectedGroupToneBinding(
    _ group: PolicyCanvasGroup
  ) -> Binding<PolicyCanvasGroupTone> {
    Binding(
      get: { group.tone },
      set: { viewModel.commitSelectedGroupTone($0) }
    )
  }
}
