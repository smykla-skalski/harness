import HarnessMonitorKit

/// Inspector commit entry points. Each `commit*` method captures the current
/// value, compares against the proposed value, and routes through
/// `mutate(_:)` so the change lands on the undo stack as one entry. Text
/// fields hold per-keystroke writes in local @State and call these on Enter
/// or focus-loss; pickers call directly on selection change because picker
/// writes are atomic. Daemon-rejected commits surface through the standard
/// autosave-rejection toast — single-field commits do not stage a separate
/// recovery affordance because the value is recoverable from the user's
/// memory and the inspector reflects the rolled-back state immediately.
extension PolicyCanvasViewModel {
  /// Commit a node title edit through the undo funnel.
  func commitSelectedNodeTitle(_ title: String) {
    guard case .node(let id) = selection,
      let node = nodes.first(where: { $0.id == id }),
      node.title != title
    else {
      return
    }
    mutate(.setNodeTitle(id: id, from: node.title, to: title))
  }

  /// Commit a node kind picker change through the undo funnel. The applier
  /// captures the edges that the new kind would prune so undo restores both
  /// the prior kind and every dropped connection in one Cmd-Z step.
  func commitSelectedNodeKind(_ kind: PolicyCanvasNodeKind) {
    guard case .node(let id) = selection,
      let node = nodes.first(where: { $0.id == id }),
      node.kind != kind
    else {
      return
    }
    mutate(
      .setNodeKind(
        id: id,
        from: node.kind,
        to: kind,
        fromSubtitle: node.subtitle,
        toSubtitle: kind.subtitle,
        fromPolicyKind: node.policyKind,
        toPolicyKind: taskBoardPolicyNodeKind(for: kind),
        removedEdges: []
      )
    )
  }

  /// Commit a node group picker change through the undo funnel. `nil` means
  /// "no group". Inspector picker tag maps the sentinel "none" string to
  /// `nil` before calling here.
  func commitSelectedNodeGroup(_ groupID: String?) {
    guard case .node(let id) = selection,
      let node = nodes.first(where: { $0.id == id }),
      node.groupID != groupID
    else {
      return
    }
    mutate(.setNodeGroup(id: id, from: node.groupID, to: groupID))
  }

  /// Commit a node subtitle edit through the undo funnel.
  func commitSelectedNodeSubtitle(_ subtitle: String) {
    guard case .node(let id) = selection,
      let node = nodes.first(where: { $0.id == id }),
      node.subtitle != subtitle
    else {
      return
    }
    mutate(.setNodeSubtitle(id: id, from: node.subtitle, to: subtitle))
  }

  /// Commit a node policy-kind picker change through the undo funnel.
  func commitSelectedNodePolicyKind(_ policyKind: TaskBoardPolicyPipelineNodeKind) {
    guard case .node(let id) = selection,
      let node = nodes.first(where: { $0.id == id })
    else {
      return
    }
    let previous = node.policyKind
    guard previous != policyKind else {
      return
    }
    mutate(.setNodePolicyKind(id: id, from: previous, to: policyKind))
  }

  /// Commit an edge condition edit through the undo funnel.
  func commitSelectedEdgeCondition(_ condition: String) {
    guard case .edge(let id) = selection,
      let edge = edges.first(where: { $0.id == id }),
      edge.condition != condition
    else {
      return
    }
    mutate(.setEdgeCondition(id: id, from: edge.condition, to: condition))
  }

  /// Commit an edge label edit through the undo funnel.
  func commitSelectedEdgeLabel(_ label: String) {
    guard case .edge(let id) = selection,
      let edge = edges.first(where: { $0.id == id }),
      edge.label != label
    else {
      return
    }
    mutate(.setEdgeLabel(id: id, from: edge.label, to: label))
  }

  /// Commit an edge kind override through the undo funnel. Surfaced by
  /// the inspector kind picker so the user can correct a misclassified
  /// condition string (e.g. force `.error` when the heuristic landed on
  /// `.control`).
  func commitSelectedEdgeKind(_ kind: PolicyCanvasEdgeKind) {
    guard case .edge(let id) = selection,
      let edge = edges.first(where: { $0.id == id }),
      edge.kind != kind
    else {
      return
    }
    mutate(.setEdgeKind(id: id, from: edge.kind, to: kind))
  }

  /// Commit an edge port-pin toggle through the undo funnel. Surfaced by
  /// the inspector port-pin toggle - flipping to `false` lets the
  /// visibility router walk all 4-side combinations to pick the
  /// lowest-bend route.
  func commitSelectedEdgePinnedPortSide(_ pinned: Bool) {
    guard case .edge(let id) = selection,
      let edge = edges.first(where: { $0.id == id }),
      edge.pinnedPortSide != pinned
    else {
      return
    }
    mutate(.setEdgePinnedPortSide(id: id, from: edge.pinnedPortSide, to: pinned))
  }

  /// Commit a group title edit through the undo funnel.
  func commitSelectedGroupTitle(_ title: String) {
    guard case .group(let id) = selection,
      let group = groups.first(where: { $0.id == id }),
      group.title != title
    else {
      return
    }
    mutate(.setGroupTitle(id: id, from: group.title, to: title))
  }

  /// Commit a group tone picker change through the undo funnel.
  func commitSelectedGroupTone(_ tone: PolicyCanvasGroupTone) {
    guard case .group(let id) = selection,
      let group = groups.first(where: { $0.id == id }),
      group.tone != tone
    else {
      return
    }
    mutate(.setGroupTone(id: id, from: group.tone, to: tone))
  }

  // MARK: - Compound policy-kind helpers
  //
  // The remaining helpers compose a `setNodePolicyKind` change with a
  // mutator that adjusts a specific policy-kind field (action, threshold,
  // evidence, reason code, rule id, decision). Each picker / stepper /
  // text field calls one of these; the helper builds the new
  // `TaskBoardPolicyPipelineNodeKind` and routes through the funnel.

  /// Commit a policy-action picker change.
  func commitSelectedPolicyAction(_ action: TaskBoardPolicyAction) {
    commitPolicyKindMutation { kind in
      kind.kind = "action_gate"
      kind.action = action
      kind.actions = [action]
    }
  }

  /// Commit a risk-threshold stepper change. Clamped to 0...100 to match the
  /// daemon contract.
  func commitSelectedRiskThreshold(_ threshold: Int) {
    commitPolicyKindMutation { kind in
      kind.kind = "risk_classifier"
      kind.field = kind.field ?? .riskScore
      kind.threshold = UInt8(min(100, max(0, threshold)))
      kind.highRiskReasonCode = kind.highRiskReasonCode ?? "risk_above_threshold"
      kind.missingReasonCode = kind.missingReasonCode ?? "risk_missing"
    }
  }

  /// Commit an evidence-field picker change.
  func commitSelectedEvidenceField(_ field: TaskBoardPolicyEvidenceField) {
    commitPolicyKindMutation { kind in
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
  }

  /// Commit a reason-code text field change.
  func commitSelectedReasonCode(_ reasonCode: String) {
    commitPolicyKindMutation { kind in
      kind.reasonCode = reasonCode
      if kind.kind == "supervisor_rule" {
        kind.reasonCodes = [reasonCode]
      }
    }
  }

  /// Commit a supervisor-rule id text field change.
  func commitSelectedRuleID(_ ruleID: String) {
    commitPolicyKindMutation { kind in
      kind.kind = "supervisor_rule"
      kind.ruleId = ruleID
    }
  }

  /// Commit a gate-decision picker change.
  func commitSelectedDecision(_ decision: String) {
    commitPolicyKindMutation { kind in
      kind.kind = "supervisor_rule"
      kind.decision = decision
    }
  }

  /// Compose `setNodePolicyKind` from a closure that mutates a fresh copy of
  /// the selected node's policy-kind. Returns early when nothing about the
  /// kind changed (no-op pickers and refresh callbacks must not log a
  /// phantom undo step).
  private func commitPolicyKindMutation(
    _ mutator: (inout TaskBoardPolicyPipelineNodeKind) -> Void
  ) {
    guard case .node(let id) = selection,
      let node = nodes.first(where: { $0.id == id })
    else {
      return
    }
    let previous = node.policyKind ?? taskBoardPolicyNodeKind(for: node.kind)
    var next = previous
    mutator(&next)
    guard previous != next else {
      return
    }
    mutate(.setNodePolicyKind(id: id, from: node.policyKind, to: next))
  }
}
