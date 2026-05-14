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
    if let node = viewModel.selectedNode {
      nodeSection(node)
    } else if let group = viewModel.selectedGroup {
      groupSection(group)
    } else if let edge = viewModel.selectedEdge {
      edgeSection(edge)
    } else {
      canvasSection
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

  private var nodeTitleField: some View {
    PolicyCanvasInspectorField(label: "Name") {
      TextField("Node name", text: selectedNodeTitleBinding)
        .textFieldStyle(.roundedBorder)
        .scaledFont(.callout)
        .focused($focusedField, equals: .nodeTitle)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.policyCanvasInspectorField("node-title")
        )
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

  private static let noneGroupTag = "__none__"

  private var selectedNodeTitleBinding: Binding<String> {
    Binding(
      get: { viewModel.selectedNode?.title ?? "" },
      set: { viewModel.updateSelectedNodeTitle($0) }
    )
  }

  private var selectedNodeKindBinding: Binding<PolicyCanvasNodeKind> {
    Binding(
      get: { viewModel.selectedNode?.kind ?? .condition },
      set: { viewModel.updateSelectedNodeKind($0) }
    )
  }

  private var selectedNodeGroupBinding: Binding<String> {
    Binding(
      get: { viewModel.selectedNode?.groupID ?? Self.noneGroupTag },
      set: { viewModel.updateSelectedNodeGroup($0 == Self.noneGroupTag ? nil : $0) }
    )
  }

  private var selectedGroupTitleBinding: Binding<String> {
    Binding(
      get: { viewModel.selectedGroup?.title ?? "" },
      set: { viewModel.updateSelectedGroupTitle($0) }
    )
  }

  private var selectedEdgeLabelBinding: Binding<String> {
    Binding(
      get: { viewModel.selectedEdge?.label ?? "" },
      set: { viewModel.updateSelectedEdgeLabel($0) }
    )
  }

  private func selectedPolicyActionBinding(
    _ policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> Binding<TaskBoardPolicyAction> {
    Binding(
      get: { policyKind.actions.first ?? policyKind.action ?? .spawnAgent },
      set: { viewModel.updateSelectedPolicyAction($0) }
    )
  }

  private func selectedEvidenceFieldBinding(
    _ policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> Binding<TaskBoardPolicyEvidenceField> {
    Binding(
      get: { policyKind.checks.first?.field ?? policyKind.field ?? .checksGreen },
      set: { viewModel.updateSelectedEvidenceField($0) }
    )
  }

  private func selectedRiskThresholdBinding(
    _ policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> Binding<Int> {
    Binding(
      get: { Int(policyKind.threshold ?? 0) },
      set: { viewModel.updateSelectedRiskThreshold($0) }
    )
  }

  private func selectedReasonCodeBinding(
    _ policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> Binding<String> {
    Binding(
      get: { policyKind.reasonCode ?? policyKind.reasonCodes.first ?? "" },
      set: { viewModel.updateSelectedReasonCode($0) }
    )
  }

  private func selectedRuleIDBinding(
    _ policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> Binding<String> {
    Binding(
      get: { policyKind.ruleId ?? "" },
      set: { viewModel.updateSelectedRuleID($0) }
    )
  }

  private func selectedDecisionBinding(
    _ policyKind: TaskBoardPolicyPipelineNodeKind
  ) -> Binding<String> {
    Binding(
      get: { policyKind.decision ?? "allow" },
      set: { viewModel.updateSelectedDecision($0) }
    )
  }

  private var canvasMetrics: some View {
    PolicyCanvasInspectorSection(title: "Policy") {
      PolicyCanvasInspectorRow(label: "Summary", value: viewModel.policySummary)
      PolicyCanvasInspectorRow(
        label: "Zoom",
        value: "\(Int((viewModel.zoom * 100).rounded()))%"
      )
      PolicyCanvasInspectorRow(
        label: "Promote",
        value: viewModel.promoteDisabledReason ?? "Ready"
      )
      if let validation = viewModel.latestSimulation?.validation {
        PolicyCanvasInspectorRow(
          label: "Validation",
          value: validation.issues.first?.code ?? "OK"
        )
      }
    }
  }
}
