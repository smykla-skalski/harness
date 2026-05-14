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

      Text(statusLine)
        .scaledFont(.caption)
        .foregroundStyle(.white.opacity(0.78))
        .lineLimit(1)
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
      nodeTitleField
      nodeKindField
      nodeGroupField
      PolicyCanvasInspectorRow(
        label: "Position",
        value: "\(Int(node.position.x)), \(Int(node.position.y))"
      )
      nodePolicyControls(node)
    }
  }

  @ViewBuilder
  private var nodeTitleField: some View {
    PolicyCanvasInspectorField(label: "Name") {
      if let node = viewModel.selectedNode {
        PolicyCanvasInspectorRenameField(
          viewModel: viewModel,
          nodeID: node.id,
          originalTitle: node.title,
          focusedField: $focusedField
        )
      } else {
        // Selection is stale (node was deleted under us). Render a
        // placeholder so the inspector row still renders something while
        // the next selection change resolves the empty state.
        Text("—")
          .scaledFont(.callout)
          .foregroundStyle(.white.opacity(0.5))
      }
    }
  }

  private var nodeKindField: some View {
    PolicyCanvasInspectorField(label: "Kind") {
      Picker("Node kind", selection: selectedNodeKindBinding) {
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

  private var nodeGroupField: some View {
    PolicyCanvasInspectorField(label: "Group") {
      Picker("Node group", selection: selectedNodeGroupBinding) {
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
        TextField("Group name", text: selectedGroupTitleBinding)
          .textFieldStyle(.roundedBorder)
          .scaledFont(.callout)
          .focused($focusedField, equals: .groupTitle)
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.policyCanvasInspectorField("group-title")
          )
      }
      PolicyCanvasInspectorRow(label: "Nodes", value: "\(viewModel.nodes(in: group.id).count)")
      PolicyCanvasInspectorRow(
        label: "Frame",
        value: "\(Int(group.frame.width)) x \(Int(group.frame.height))"
      )
    }
  }

  private func edgeSection(_ edge: PolicyCanvasEdge) -> some View {
    PolicyCanvasInspectorSection(title: "Edge") {
      PolicyCanvasInspectorField(label: "Label") {
        TextField("Edge label", text: selectedEdgeLabelBinding)
          .textFieldStyle(.roundedBorder)
          .scaledFont(.callout)
          .focused($focusedField, equals: .edgeLabel)
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.policyCanvasInspectorField("edge-label")
          )
      }
      PolicyCanvasInspectorRow(label: "Source", value: edge.source.nodeID)
      PolicyCanvasInspectorRow(label: "Target", value: edge.target.nodeID)
    }
  }

  private var canvasSection: some View {
    PolicyCanvasInspectorSection(title: "Canvas") {
      PolicyCanvasInspectorRow(label: "Selection", value: "None")
      PolicyCanvasInspectorRow(label: "Mode", value: viewModel.selectedTab.title)
    }
  }

  @ViewBuilder
  private func nodePolicyControls(_ node: PolicyCanvasNode) -> some View {
    let policyKind = node.policyKind ?? taskBoardPolicyNodeKind(for: node.kind)
    switch policyKind.kind {
    case "action_gate":
      policyActionField(policyKind)
    case "evidence_check":
      policyEvidenceField(policyKind)
    case "risk_classifier":
      riskThresholdField(policyKind)
    case "human_gate", "consensus_gate", "dry_run_gate":
      reasonCodeField(policyKind)
    case "supervisor_rule":
      supervisorRuleFields(policyKind)
    default:
      PolicyCanvasInspectorRow(label: "Binding", value: policyKind.kind)
    }
  }

  private func policyActionField(
    _ policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> some View {
    PolicyCanvasInspectorField(label: "Action") {
      Picker("Action binding", selection: selectedPolicyActionBinding(policyKind)) {
        ForEach(TaskBoardPolicyAction.allCases) { action in
          Text(action.policyCanvasTitle).tag(action)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.policyCanvasInspectorField("action-binding")
      )
    }
  }

  private func policyEvidenceField(
    _ policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> some View {
    PolicyCanvasInspectorField(label: "Evidence") {
      Picker("Evidence field", selection: selectedEvidenceFieldBinding(policyKind)) {
        ForEach(TaskBoardPolicyEvidenceField.allCases, id: \.self) { field in
          Text(field.policyCanvasTitle).tag(field)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.policyCanvasInspectorField("evidence-field")
      )
    }
  }

  private func riskThresholdField(
    _ policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> some View {
    PolicyCanvasInspectorField(label: "Risk") {
      Stepper(value: selectedRiskThresholdBinding(policyKind), in: 0...100) {
        Text("\(policyKind.threshold.map(Int.init) ?? 0)")
          .scaledFont(.caption.monospacedDigit().weight(.semibold))
          .foregroundStyle(.white.opacity(0.86))
      }
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.policyCanvasInspectorField("risk-threshold")
      )
    }
  }

  private func reasonCodeField(
    _ policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> some View {
    PolicyCanvasInspectorField(label: "Reason") {
      TextField("Reason code", text: selectedReasonCodeBinding(policyKind))
        .textFieldStyle(.roundedBorder)
        .scaledFont(.callout)
        .focused($focusedField, equals: .reasonCode)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.policyCanvasInspectorField("reason-code")
        )
    }
  }

  private func supervisorRuleFields(
    _ policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      PolicyCanvasInspectorField(label: "Rule") {
        TextField("Rule id", text: selectedRuleIDBinding(policyKind))
          .textFieldStyle(.roundedBorder)
          .scaledFont(.callout)
          .focused($focusedField, equals: .ruleID)
          .accessibilityIdentifier(
            HarnessMonitorAccessibility.policyCanvasInspectorField("rule-id")
          )
      }
      PolicyCanvasInspectorField(label: "Decision") {
        Picker("Gate behavior", selection: selectedDecisionBinding(policyKind)) {
          Text("Allow").tag("allow")
          Text("Deny").tag("deny")
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.policyCanvasInspectorField("gate-behavior")
        )
      }
    }
  }

}
