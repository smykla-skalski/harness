import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

struct PolicyCanvasEditForm: View {
  let viewModel: PolicyCanvasViewModel
  let statusLine: String
  @FocusState.Binding var focusedField: PolicyCanvasFocusedField?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        header
        selectionDetails
      }
      .padding(16)
    }
    .background(PolicyCanvasVisualStyle.panelBackground)
    .accessibilityElement(children: .contain)
  }

  var header: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(inspectorTitle)
        .scaledFont(.headline.weight(.semibold))
        .foregroundStyle(PolicyCanvasVisualStyle.primaryText)

      Text(inspectorSubtitle)
        .scaledFont(.caption)
        .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
        .fixedSize(horizontal: false, vertical: true)

      // Status line announces commit outcomes ("Node subtitle updated",
      // "Restored Decision wall", etc.) plus group-acceptance drop
      // signals — VoiceOver users only learn the edit landed via this
      // line, so it ships as a polite live region per WCAG 4.1.3.
      Text(statusLine)
        .scaledFont(.caption)
        .foregroundStyle(PolicyCanvasVisualStyle.tertiaryText)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLiveRegion(.polite)
    }
  }

  @ViewBuilder var selectionDetails: some View {
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
      emptySelectionSection
      canvasSection
      edgeKindCountsSection
    }
  }

  /// Inspector readout shown when the user has more than one element
  /// selected. Names each element kind separately because the rotor-aware
  /// "N items selected" string would lose the breakdown VO users need to
  /// reason about a multi-delete. The section is intentionally inert —
  /// inspector-side property edits make no sense on a mixed selection.
  var multiSelectionSection: some View {
    let nodeCount = viewModel.selectedNodeIDs.count
    let edgeCount = viewModel.selectedEdgeIDs.count
    let groupCount = viewModel.selectedGroupIDs.count
    return PolicyCanvasInspectorSection(title: "Selection details") {
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

  var emptySelectionSection: some View {
    PolicyCanvasInspectorSection(title: "Get started") {
      Text(
        "Select a step, path, or group on the canvas to edit its behavior and review any linked issues."
      )
      .scaledFont(.caption)
      .foregroundStyle(PolicyCanvasVisualStyle.secondaryText)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  func nodeSection(_ node: PolicyCanvasNode) -> some View {
    PolicyCanvasInspectorSection(title: "Step details") {
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
      nodeAutomationBindingControls(node)
      nodeAutomationPolicyPreview(node)
    }
  }

  /// Wave 4K P08 subtitle field. Per-keystroke writes stay in the commit-
  /// text-field's local @State; the funnel only sees the resulting string on
  /// Enter or focus-loss so the undo stack carries one entry per committed
  /// subtitle edit.
  func nodeSubtitleField(_ node: PolicyCanvasNode) -> some View {
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
  func nodePolicyKindField(_ node: PolicyCanvasNode) -> some View {
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
  func nodeTitleField(_ node: PolicyCanvasNode) -> some View {
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
  func nodeKindField(_ node: PolicyCanvasNode) -> some View {
    PolicyCanvasInspectorField(label: "Kind") {
      Picker("Node kind", selection: selectedNodeKindBinding(node)) {
        ForEach(PolicyCanvasNodeKind.authoringCases(including: node.kind)) { kind in
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

  func nodeGroupField(_ node: PolicyCanvasNode) -> some View {
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

  func groupSection(_ group: PolicyCanvasGroup) -> some View {
    PolicyCanvasInspectorSection(title: "Group details") {
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
  func groupToneField(_ group: PolicyCanvasGroup) -> some View {
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

  func edgeSection(_ edge: PolicyCanvasEdge) -> some View {
    PolicyCanvasInspectorSection(title: "Connection details") {
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
        PolicyCanvasInspectorEdgeKindPicker(kind: edge.kind) { newKind in
          viewModel.commitSelectedEdgeKind(newKind)
        }
      }
      PolicyCanvasInspectorField(label: "Port pin") {
        PolicyCanvasInspectorEdgePinToggle(
          pinnedPortSide: edge.pinnedPortSide,
          isLockedByKind: edge.kind == .error
        ) { newValue in
          viewModel.commitSelectedEdgePinnedPortSide(newValue)
        }
      }
      PolicyCanvasInspectorEdgeBranchList(viewModel: viewModel, edge: edge)
      PolicyCanvasInspectorRow(label: "Source", value: edge.source.nodeID)
      PolicyCanvasInspectorRow(label: "Target", value: edge.target.nodeID)
    }
  }

  var canvasSection: some View {
    PolicyCanvasInspectorSection(title: "Policy summary") {
      // Mode is intentionally absent here. The Draft/Simulation/Promote
      // segmented control above the canvas owns the mode display; an
      // inspector row duplicating it wasted the panel on a value the
      // user has already seen.
      PolicyCanvasInspectorRow(label: "Nodes", value: "\(viewModel.nodes.count)")
      PolicyCanvasInspectorRow(label: "Edges", value: "\(viewModel.edges.count)")
      PolicyCanvasInspectorRow(label: "Groups", value: "\(viewModel.groups.count)")
      PolicyCanvasInspectorRow(label: "Zoom", value: zoomDisplayValue)
      PolicyCanvasInspectorRow(label: "Draft", value: viewModel.draftStatusText)
      PolicyCanvasInspectorRow(label: "Validate", value: viewModel.validationSummaryText)
      PolicyCanvasInspectorRow(label: "Promote", value: viewModel.promotionStatusText)
      canvasAutomationPolicySummaryRow
    }
  }

  /// Zoom percentage rendered without trailing decimals. Matches the
  /// canvas chrome's HUD format so the two surfaces don't show
  /// different precisions for the same value.
  var zoomDisplayValue: String {
    let percent = Int((viewModel.zoom * 100).rounded())
    return "\(percent)%"
  }

  @ViewBuilder
  fileprivate func nodePolicyControls(_ node: PolicyCanvasNode) -> some View {
    PolicyCanvasInspectorNodePolicyControls(
      viewModel: viewModel,
      node: node,
      focusedField: $focusedField
    )
  }

}
