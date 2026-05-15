import HarnessMonitorKit
import SwiftUI

struct PolicyCanvasInspector: View {
  let viewModel: PolicyCanvasViewModel
  let statusLine: String
  @FocusState.Binding var focusedField: PolicyCanvasFocusedField?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        header
        selectionDetails
        canvasMetrics
      }
      .padding(16)
    }
    .background(Color(red: 0.08, green: 0.09, blue: 0.12))
    .overlay(alignment: .leading) {
      Rectangle()
        .fill(.white.opacity(0.08))
        .frame(width: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasInspector)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text("Inspector")
        .scaledFont(.headline.weight(.semibold))
        .foregroundStyle(.white)

      // Status line announces commit outcomes ("Node subtitle updated",
      // "Restored Decision wall", etc.) plus group-acceptance drop
      // signals — VoiceOver users only learn the edit landed via this
      // line, so it ships as a polite live region per WCAG 4.1.3.
      Text(statusLine)
        .scaledFont(.caption)
        .foregroundStyle(.white.opacity(0.78))
        .lineLimit(1)
        .accessibilityLiveRegion(.polite)
    }
  }

  @ViewBuilder private var selectionDetails: some View {
    if !viewModel.secondarySelections.isEmpty {
      // Multi-selection: surface the count explicitly so the inspector
      // does not pretend it is editing a single primary while the user
      // has many nodes lit. The single-node editor below this branch
      // would otherwise pick a non-deterministic head and the secondary
      // selections would be silently ignored on inspector-side actions.
      multiSelectionSection
    } else if let node = viewModel.selectedNode {
      nodeSection(node)
      PolicyCanvasInspectorIssuesSection(viewModel: viewModel, selection: .node(node.id))
    } else if let group = viewModel.selectedGroup {
      groupSection(group)
    } else if let edge = viewModel.selectedEdge {
      edgeSection(edge)
      PolicyCanvasInspectorIssuesSection(viewModel: viewModel, selection: .edge(edge.id))
    } else {
      canvasSection
    }
  }

  /// Inspector readout shown when the user has more than one element
  /// selected. Names each element kind separately because the rotor-aware
  /// "N items selected" string would lose the breakdown VO users need to
  /// reason about a multi-delete. The section is intentionally inert —
  /// inspector-side property edits make no sense on a mixed selection.
  private var multiSelectionSection: some View {
    let nodeCount = viewModel.selectedNodeIDs.count
    let edgeCount = viewModel.selectedEdgeIDs.count
    let groupCount = viewModel.selectedGroupIDs.count
    return PolicyCanvasInspectorSection(title: "Multiple selected") {
      PolicyCanvasInspectorRow(
        label: "Total",
        value: "\(nodeCount + edgeCount + groupCount)"
      )
      if nodeCount > 0 {
        PolicyCanvasInspectorRow(label: "Nodes", value: "\(nodeCount)")
      }
      if edgeCount > 0 {
        PolicyCanvasInspectorRow(label: "Edges", value: "\(edgeCount)")
      }
      if groupCount > 0 {
        PolicyCanvasInspectorRow(label: "Groups", value: "\(groupCount)")
      }
    }
  }

  private func nodeSection(_ node: PolicyCanvasNode) -> some View {
    PolicyCanvasInspectorSection(title: "Node") {
      nodeTitleField(node)
      nodeSubtitleField(node)
      nodeKindField(node)
      nodePolicyKindField(node)
      nodeGroupField(node)
      PolicyCanvasInspectorRow(
        label: "Position",
        value: "\(Int(node.position.x)), \(Int(node.position.y))"
      )
      nodePolicyControls(node)
    }
  }

  /// Wave 4K P08 subtitle field. Per-keystroke writes stay in the commit-
  /// text-field's local @State; the funnel only sees the resulting string on
  /// Enter or focus-loss so the undo stack carries one entry per committed
  /// subtitle edit.
  private func nodeSubtitleField(_ node: PolicyCanvasNode) -> some View {
    PolicyCanvasInspectorField(label: "Subtitle") {
      PolicyCanvasInspectorCommitTextField(
        label: "Subtitle",
        placeholder: "Subtitle",
        value: node.subtitle,
        focusField: .nodeSubtitle,
        focusedField: $focusedField,
        accessibilityIdentifier:
          HarnessMonitorAccessibility.policyCanvasInspectorField("node-subtitle"),
        commit: { viewModel.commitSelectedNodeSubtitle($0) }
      )
    }
  }

  /// Wave 4K P08 policy-binding picker. Surfaces the kinds the daemon
  /// understands as a discrete picker — the user can swap a node between
  /// `action_gate`, `evidence_check`, `risk_classifier`, the gate variants
  /// and `supervisor_rule` without re-typing the surrounding fields.
  private func nodePolicyKindField(_ node: PolicyCanvasNode) -> some View {
    PolicyCanvasInspectorField(label: "Binding") {
      Picker("Policy binding", selection: selectedNodePolicyKindStringBinding(node)) {
        ForEach(Self.policyKindOptions, id: \.self) { kindString in
          Text(Self.policyKindTitle(for: kindString)).tag(kindString)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.policyCanvasInspectorField("node-policy-kind")
      )
    }
  }

  /// Wave 4K P08 name field. Routes through the unified
  /// PolicyCanvasInspectorCommitTextField wrapper so per-keystroke writes
  /// stay in the wrapper's local @State and only the resulting string lands
  /// through `mutate(_:)`.
  private func nodeTitleField(_ node: PolicyCanvasNode) -> some View {
    PolicyCanvasInspectorField(label: "Name") {
      PolicyCanvasInspectorCommitTextField(
        label: "Name",
        placeholder: "Node name",
        value: node.title,
        focusField: .nodeTitle,
        focusedField: $focusedField,
        accessibilityIdentifier:
          HarnessMonitorAccessibility.policyCanvasInspectorField("node-title"),
        commit: { viewModel.commitSelectedNodeTitle($0) }
      )
    }
  }

  /// Wave 4K kind picker. Routes through `commitSelectedNodeKind` so the
  /// undo funnel captures the prior kind plus every edge the kind switch
  /// prunes — Cmd-Z restores both in one step.
  private func nodeKindField(_ node: PolicyCanvasNode) -> some View {
    PolicyCanvasInspectorField(label: "Kind") {
      Picker("Node kind", selection: selectedNodeKindBinding(node)) {
        ForEach(PolicyCanvasNodeKind.allCases) { kind in
          Text(kind.title).tag(kind)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.policyCanvasInspectorField("node-kind")
      )
    }
  }

  private func nodeGroupField(_ node: PolicyCanvasNode) -> some View {
    PolicyCanvasInspectorField(label: "Group") {
      Picker("Node group", selection: selectedNodeGroupBinding(node)) {
        Text("None").tag(Self.noneGroupTag)
        ForEach(viewModel.groups) { group in
          Text(group.title).tag(group.id)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.policyCanvasInspectorField("node-group")
      )
    }
  }

  private func groupSection(_ group: PolicyCanvasGroup) -> some View {
    PolicyCanvasInspectorSection(title: "Group") {
      PolicyCanvasInspectorField(label: "Name") {
        PolicyCanvasInspectorCommitTextField(
          label: "Group name",
          placeholder: "Group name",
          value: group.title,
          focusField: .groupTitle,
          focusedField: $focusedField,
          accessibilityIdentifier:
            HarnessMonitorAccessibility.policyCanvasInspectorField("group-title"),
          commit: { viewModel.commitSelectedGroupTitle($0) }
        )
      }
      groupToneField(group)
      PolicyCanvasInspectorRow(label: "Nodes", value: "\(viewModel.nodes(in: group.id).count)")
      PolicyCanvasInspectorRow(
        label: "Frame",
        value: "\(Int(group.frame.width)) x \(Int(group.frame.height))"
      )
    }
  }

  /// Wave 4K P08 group-tone picker. Swaps the group's `tone` (intake /
  /// evaluation / release), routes through the commit funnel for undo.
  private func groupToneField(_ group: PolicyCanvasGroup) -> some View {
    PolicyCanvasInspectorField(label: "Tone") {
      Picker("Group tone", selection: selectedGroupToneBinding(group)) {
        ForEach(PolicyCanvasGroupTone.allCases, id: \.self) { tone in
          Text(tone.policyCanvasTitle).tag(tone)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.policyCanvasInspectorField("group-tone")
      )
    }
  }

  private func edgeSection(_ edge: PolicyCanvasEdge) -> some View {
    PolicyCanvasInspectorSection(title: "Edge") {
      PolicyCanvasInspectorField(label: "Label") {
        PolicyCanvasInspectorCommitTextField(
          label: "Edge label",
          placeholder: "Edge label",
          value: edge.label,
          focusField: .edgeLabel,
          focusedField: $focusedField,
          accessibilityIdentifier:
            HarnessMonitorAccessibility.policyCanvasInspectorField("edge-label"),
          commit: { viewModel.commitSelectedEdgeLabel($0) }
        )
      }
      PolicyCanvasInspectorField(label: "Condition") {
        PolicyCanvasInspectorCommitTextField(
          label: "Edge condition",
          placeholder: "Condition",
          value: edge.condition,
          focusField: .edgeCondition,
          focusedField: $focusedField,
          accessibilityIdentifier:
            HarnessMonitorAccessibility.policyCanvasInspectorField("edge-condition"),
          commit: { viewModel.commitSelectedEdgeCondition($0) }
        )
      }
      PolicyCanvasInspectorField(label: "Kind") {
        edgeKindPicker(for: edge)
      }
      PolicyCanvasInspectorField(label: "Port pin") {
        edgePinnedPortToggle(for: edge)
      }
      PolicyCanvasInspectorRow(label: "Source", value: edge.source.nodeID)
      PolicyCanvasInspectorRow(label: "Target", value: edge.target.nodeID)
    }
  }

  /// Inspector kind picker. Names each kind in plain words so the user can
  /// override the heuristic-derived `PolicyCanvasEdgeKind.derive(from:)`
  /// result when the condition string is ambiguous (e.g.
  /// `deny_list_member` could be a control branch or an error path).
  private func edgeKindPicker(for edge: PolicyCanvasEdge) -> some View {
    Picker(
      "Edge kind",
      selection: Binding(
        get: { edge.kind },
        set: { viewModel.commitSelectedEdgeKind($0) }
      )
    ) {
      ForEach(PolicyCanvasEdgeKind.allCases, id: \.self) { kind in
        Text(kindTitle(for: kind)).tag(kind)
      }
    }
    .labelsHidden()
    .pickerStyle(.menu)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasInspectorField("edge-kind"))
  }

  /// Inspector port-pin toggle. When off, the visibility router walks all
  /// 4-side anchor combinations and picks the lowest-bend route. Default
  /// is on so existing documents keep their stable port positions; flipping
  /// off is an explicit user opt-in.
  private func edgePinnedPortToggle(for edge: PolicyCanvasEdge) -> some View {
    Toggle(
      "Pin ports to their sides",
      isOn: Binding(
        get: { edge.pinnedPortSide },
        set: { viewModel.commitSelectedEdgePinnedPortSide($0) }
      )
    )
    .toggleStyle(.switch)
    .labelsHidden()
    .accessibilityLabel("Pin ports to their sides")
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.policyCanvasInspectorField("edge-pin")
    )
  }

  private func kindTitle(for kind: PolicyCanvasEdgeKind) -> String {
    switch kind {
    case .flow:
      return "Flow"
    case .control:
      return "Control"
    case .error:
      return "Error"
    }
  }

  private var canvasSection: some View {
    PolicyCanvasInspectorSection(title: "Canvas") {
      PolicyCanvasInspectorRow(label: "Selection", value: "None")
      PolicyCanvasInspectorRow(label: "Mode", value: viewModel.selectedTab.title)
    }
  }

  @ViewBuilder
  fileprivate func nodePolicyControls(_ node: PolicyCanvasNode) -> some View {
    PolicyCanvasInspectorNodePolicyControls(
      viewModel: viewModel,
      node: node,
      focusedField: $focusedField
    )
  }

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

  private func selectedNodePolicyKindStringBinding(
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

  private func selectedGroupToneBinding(
    _ group: PolicyCanvasGroup
  ) -> Binding<PolicyCanvasGroupTone> {
    Binding(
      get: { group.tone },
      set: { viewModel.commitSelectedGroupTone($0) }
    )
  }
}
