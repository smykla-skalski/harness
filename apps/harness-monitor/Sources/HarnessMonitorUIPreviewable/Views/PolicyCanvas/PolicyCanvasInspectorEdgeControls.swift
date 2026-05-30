import SwiftUI

/// Inspector kind picker for a selected edge. Lets the user override the
/// heuristic-derived `PolicyCanvasEdgeKind.derive(from:)` result when the
/// condition string is ambiguous (e.g. `deny_list_member` could be a
/// control branch or an error path). The Picker title matches the visible
/// `PolicyCanvasInspectorField` label ("Kind") so VoiceOver's accessible
/// name starts with the same word sighted users read - WCAG 2.5.3 (Label
/// in Name).
struct PolicyCanvasInspectorEdgeKindPicker: View {
  let kind: PolicyCanvasEdgeKind
  let commit: (PolicyCanvasEdgeKind) -> Void

  var body: some View {
    Picker(
      "Kind",
      selection: Binding(
        get: { kind },
        set: { commit($0) }
      )
    ) {
      ForEach(PolicyCanvasEdgeKind.allCases, id: \.self) { value in
        Text(Self.title(for: value)).tag(value)
      }
    }
    .labelsHidden()
    .pickerStyle(.menu)
    .help(
      """
      Override the heuristic-derived kind. Flow is unconditional, control is a \
      conditional branch, error is a deny path.
      """
    )
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasInspectorField("edge-kind"))
  }

  static func title(for kind: PolicyCanvasEdgeKind) -> String {
    kind.accessibilityWord.capitalized
  }
}

/// Inspector port-pin toggle. When off, the visibility router walks all
/// 4-side anchor combinations and picks the lowest-bend route. Default
/// is on so existing documents keep their stable port positions; flipping
/// off is an explicit user opt-in. The accessible label and `.help` share
/// the same "Port pin" wording the visible field carries (WCAG 2.5.3),
/// and the help text resolves the gulf of execution: a binary switch
/// with no visible signifier of the off-state effect.
///
/// When the edge's kind is `.error`, the toggle is disabled and the help
/// text explains the constraint: error edges are always pinned regardless
/// of this control, so a flex pass cannot silently relocate a deliberately
/// positioned deny-branch port. This is Norman's forcing-function pattern
/// applied to the routing layer.
struct PolicyCanvasInspectorEdgePinToggle: View {
  let pinnedPortSide: Bool
  let isLockedByKind: Bool
  let commit: (Bool) -> Void

  var body: some View {
    Toggle(
      "Port pin",
      isOn: Binding(
        get: { isLockedByKind ? true : pinnedPortSide },
        set: { commit($0) }
      )
    )
    .toggleStyle(.switch)
    .labelsHidden()
    .disabled(isLockedByKind)
    .help(helpText)
    .accessibilityLabel("Port pin")
    .accessibilityHint(accessibilityHintText)
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.policyCanvasInspectorField("edge-pin")
    )
  }

  private var helpText: String {
    if isLockedByKind {
      return
        "Error edges are always pinned. Change the edge kind to flow or control to unlock this control"
    }
    return "On keeps the current port side. Off lets the router pick the lowest-bend side"
  }

  private var accessibilityHintText: String {
    if isLockedByKind {
      // VoiceOver already announces the disabled trait via `.disabled()`;
      // the hint adds the *reason*, not the state. Leading with "Disabled"
      // would double-announce.
      return "Error edges are always pinned to prevent the router from relocating them"
    }
    return "Off lets the router pick the lowest-bend port side"
  }
}

/// Per-branch editor for a connection. A merged fan-in wire stands for several
/// daemon edges that differ only by reason code; this surfaces each as a row so
/// an author can rename its failure type (reason-code picker) or route it to a
/// different node (target picker, which splits the branch out of the merge). A
/// plain edge has one branch, so it shows just the reason-code picker - the way
/// to say "this branch fires on reviewer_not_approved" without touching the
/// shared condition string.
struct PolicyCanvasInspectorEdgeBranchList: View {
  let viewModel: PolicyCanvasViewModel
  let edge: PolicyCanvasEdge

  var body: some View {
    PolicyCanvasInspectorField(label: edge.isMerged ? "Branches" : "Reason code") {
      VStack(alignment: .leading, spacing: 10) {
        ForEach(Array(edge.branches.enumerated()), id: \.element.daemonEdgeID) { index, branch in
          branchRow(branch, index: index)
        }
        addBranchButton
      }
    }
  }

  /// One branch: on a merged wire it carries a header (index + remove) and both
  /// the reason-code and target pickers; on a plain edge it is just the reason
  /// picker. The row tints when it is the active branch (e.g. just added) so the
  /// author's eye lands on the row that still needs a reason code.
  private func branchRow(_ branch: PolicyCanvasEdgeBranch, index: Int) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      if edge.isMerged {
        HStack(spacing: 8) {
          Text("Branch \(index + 1)")
            .scaledFont(.caption.weight(.semibold))
            .foregroundStyle(PolicyCanvasVisualStyle.primaryText)
          Spacer(minLength: 0)
          Button {
            viewModel.removeBranch(edgeID: edge.id, daemonEdgeID: branch.daemonEdgeID)
          } label: {
            Image(systemName: "trash")
          }
          .buttonStyle(.borderless)
          .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
          .accessibilityLabel("Remove branch \(index + 1)")
        }
      }
      reasonCodePicker(for: branch)
      if edge.isMerged {
        targetPicker(for: branch)
      }
    }
    .padding(edge.isMerged ? 8 : 0)
    .background { branchHighlight(for: branch) }
  }

  @ViewBuilder
  private func branchHighlight(for branch: PolicyCanvasEdgeBranch) -> some View {
    if viewModel.selectedBranchDaemonEdgeID == branch.daemonEdgeID {
      RoundedRectangle(cornerRadius: 8)
        .fill(PolicyCanvasVisualStyle.activeTint.opacity(0.16))
    }
  }

  /// Append a reason-code branch. On a plain edge this promotes it to a merged
  /// wire so the same source -> target can fire on more than one failure type.
  private var addBranchButton: some View {
    Button {
      viewModel.addBranch(toEdgeID: edge.id)
    } label: {
      Label("Add branch", systemImage: "plus")
    }
    .buttonStyle(.glass)
    .controlSize(.small)
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.policyCanvasInspectorField("edge-add-branch")
    )
  }

  private func reasonCodePicker(for branch: PolicyCanvasEdgeBranch) -> some View {
    Picker(
      "Reason code",
      selection: Binding(
        get: { branch.reasonCode ?? "" },
        set: { selected in
          viewModel.commitBranchReasonCode(
            edgeID: edge.id,
            daemonEdgeID: branch.daemonEdgeID,
            from: branch.reasonCode,
            to: selected.isEmpty ? nil : selected
          )
        }
      )
    ) {
      Text("None").tag("")
      ForEach(PolicyCanvasReasonCode.ordered, id: \.self) { code in
        Text(PolicyCanvasReasonCode.displayName(code)).tag(code)
      }
    }
    .labelsHidden()
    .pickerStyle(.menu)
    .help("The daemon reason code this branch fires on")
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.policyCanvasInspectorField("branch-reason-\(branch.daemonEdgeID)")
    )
  }

  private func targetPicker(for branch: PolicyCanvasEdgeBranch) -> some View {
    Picker(
      "Target",
      selection: Binding(
        get: { branch.target.nodeID },
        set: { nodeID in
          viewModel.retargetBranch(
            edgeID: edge.id, daemonEdgeID: branch.daemonEdgeID, toNodeID: nodeID)
        }
      )
    ) {
      ForEach(viewModel.branchRetargetCandidateNodes(excludingSourceNodeID: edge.source.nodeID)) {
        node in
        Text(node.title).tag(node.id)
      }
    }
    .labelsHidden()
    .pickerStyle(.menu)
    .help("Route this failure type to a different node; it splits out of the merged wire")
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.policyCanvasInspectorField("branch-target-\(branch.daemonEdgeID)")
    )
  }
}
