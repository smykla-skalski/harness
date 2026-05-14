import HarnessMonitorKit

extension PolicyCanvasViewModel {
  func updateSelectedNodeTitle(_ title: String) {
    updateSelectedNode { node in
      node.title = title
    }
    lastActionSummary = "Node title updated"
  }

  func updateSelectedNodeKind(_ kind: PolicyCanvasNodeKind) {
    updateSelectedNode { node in
      guard node.kind != kind else {
        return
      }
      node.kind = kind
      node.subtitle = kind.subtitle
      node.inputPorts = Self.ports(for: kind.inputPortTitles, kind: .input)
      node.outputPorts = Self.ports(for: kind.outputPortTitles, kind: .output)
      node.policyKind = taskBoardPolicyNodeKind(for: kind)
    }
    pruneDanglingEdges()
    lastActionSummary = "Node kind updated"
  }

  func updateSelectedNodeGroup(_ groupID: String?) {
    updateSelectedNode { node in
      node.groupID = groupID
    }
    reconcileGroupFrames()
    lastActionSummary = "Node group updated"
  }

  func updateSelectedGroupTitle(_ title: String) {
    guard case .group(let id) = selection,
      let index = groups.firstIndex(where: { $0.id == id })
    else {
      return
    }
    groups[index].title = title
    isDirty = true
    lastActionSummary = "Group title updated"
  }

  func updateSelectedEdgeLabel(_ label: String) {
    guard case .edge(let id) = selection,
      let index = edges.firstIndex(where: { $0.id == id })
    else {
      return
    }
    edges[index].label = label
    markEdgeEdited(id)
    isDirty = true
    lastActionSummary = "Edge label updated"
  }

  func updateSelectedPolicyAction(_ action: TaskBoardPolicyAction) {
    updateSelectedPolicyKind { kind in
      kind.kind = "action_gate"
      kind.action = action
      kind.actions = [action]
    }
    lastActionSummary = "Policy action updated"
  }

  func updateSelectedRiskThreshold(_ threshold: Int) {
    updateSelectedPolicyKind { kind in
      kind.kind = "risk_classifier"
      kind.field = kind.field ?? .riskScore
      kind.threshold = UInt8(min(100, max(0, threshold)))
      kind.highRiskReasonCode = kind.highRiskReasonCode ?? "risk_above_threshold"
      kind.missingReasonCode = kind.missingReasonCode ?? "risk_missing"
    }
    lastActionSummary = "Risk threshold updated"
  }

  func updateSelectedEvidenceField(_ field: TaskBoardPolicyEvidenceField) {
    updateSelectedPolicyKind { kind in
      kind.kind = "evidence_check"
      kind.checks = [
        TaskBoardPolicyEvidenceCheck(
          field: field,
          pass: TaskBoardPolicyEvidencePredicate(predicate: .isTrue),
          failReasonCode: "evidence_failed",
          missingReasonCode: "evidence_missing"
        )
      ]
    }
    lastActionSummary = "Evidence field updated"
  }

  func updateSelectedReasonCode(_ reasonCode: String) {
    updateSelectedPolicyKind { kind in
      kind.reasonCode = reasonCode
      if kind.kind == "supervisor_rule" {
        kind.reasonCodes = [reasonCode]
      }
    }
    lastActionSummary = "Reason code updated"
  }

  func updateSelectedRuleID(_ ruleID: String) {
    updateSelectedPolicyKind { kind in
      kind.kind = "supervisor_rule"
      kind.ruleId = ruleID
    }
    lastActionSummary = "Supervisor rule updated"
  }

  func updateSelectedDecision(_ decision: String) {
    updateSelectedPolicyKind { kind in
      kind.kind = "supervisor_rule"
      kind.decision = decision
    }
    lastActionSummary = "Gate behavior updated"
  }

  private func updateSelectedNode(_ update: (inout PolicyCanvasNode) -> Void) {
    guard case .node(let id) = selection,
      let index = nodes.firstIndex(where: { $0.id == id })
    else {
      return
    }
    markNodeEdited(id)
    update(&nodes[index])
    isDirty = true
  }

  private func updateSelectedPolicyKind(
    _ update: (inout TaskBoardPolicyPipelineNodeKind) -> Void
  ) {
    updateSelectedNode { node in
      var policyKind = node.policyKind ?? taskBoardPolicyNodeKind(for: node.kind)
      update(&policyKind)
      node.policyKind = policyKind
    }
  }

  private func pruneDanglingEdges() {
    edges.removeAll { edge in
      !portExists(edge.source) || !portExists(edge.target)
    }
  }

  private func portExists(_ endpoint: PolicyCanvasPortEndpoint) -> Bool {
    guard let node = node(endpoint.nodeID) else {
      return false
    }
    let ports = endpoint.kind == .input ? node.inputPorts : node.outputPorts
    return ports.contains { $0.id == endpoint.portID }
  }

  private static func ports(
    for titles: [String],
    kind: PolicyCanvasPortKind
  ) -> [PolicyCanvasPort] {
    titles.map { title in
      PolicyCanvasPort(id: "\(kind.rawValue)-\(title)", title: title, kind: kind)
    }
  }
}
