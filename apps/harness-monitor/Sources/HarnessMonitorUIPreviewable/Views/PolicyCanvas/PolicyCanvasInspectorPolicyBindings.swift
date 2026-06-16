import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import HarnessMonitorPolicyModels
import SwiftUI

extension PolicyCanvasEditForm {
  /// Discrete policy-kind options surfaced by the picker. Order matches the
  /// daemon's enum walk: trigger -> action gate -> evidence -> risk -> human
  /// -> consensus -> dry-run -> supervisor. Tag identity is the kind string
  /// so `Picker` does not require `Hashable` on the full
  /// `PolicyGraphNodeKind` struct (it carries non-Hashable
  /// payloads). `defaultPolicyKind(for:)` rebuilds the full struct with
  /// sensible defaults when the user picks a kind.
  static let policyKindOptions: [String] = PolicyCanvasNodeKind.allCases.map(\.rawValue)

  static func policyKindTitle(for kind: String) -> String {
    PolicyCanvasNodeKind(rawValue: kind)?.title
      ?? kind.replacingOccurrences(of: "_", with: " ").capitalized
  }

  /// Build a `PolicyGraphNodeKind` for the given kind string,
  /// preserving as much existing payload as possible. When the user picks
  /// the same kind back, the result is byte-equal to the source; otherwise
  /// the result carries the minimal sensible defaults for the new kind so
  /// the daemon round-trip succeeds without a follow-up edit.
  static func defaultPolicyKind(
    for kindString: String,
    existing: PolicyGraphNodeKind?
  ) -> PolicyGraphNodeKind {
    if let existing, existing.discriminator == kindString {
      return existing
    }
    return PolicyCanvasNodeKind(rawValue: kindString)?.defaultPolicyKind
      ?? PolicyCanvasNodeKind.humanGate.defaultPolicyKind
  }

  func selectedNodePolicyKindStringBinding(
    _ node: PolicyCanvasNode
  ) -> Binding<String> {
    Binding(
      get: {
        node.policyKind?.discriminator ?? node.kind.rawValue
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
