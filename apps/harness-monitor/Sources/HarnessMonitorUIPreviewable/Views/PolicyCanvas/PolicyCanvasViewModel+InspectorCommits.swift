import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import HarnessMonitorPolicyModels

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
  ///
  /// The policy binding only resets when the new visual kind is incompatible
  /// with the existing binding. A binding is compatible when its kind string
  /// already equals the new kind's default policy kind string, so a user who
  /// customized the binding (e.g. a risk threshold) keeps that work when they
  /// pick the matching visual kind. The picker no longer silently clobbers the
  /// binding on every change.
  func commitSelectedNodeKind(_ kind: PolicyCanvasNodeKind) {
    guard case .node(let id) = selection,
      let node = nodes.first(where: { $0.id == id }),
      node.kind != kind
    else {
      return
    }
    let toPolicyKind = policyKind(for: kind, preserving: node.policyKind)
    mutate(
      .setNodeKind(
        id: id,
        from: node.kind,
        to: kind,
        fromSubtitle: node.subtitle,
        toSubtitle: kind.subtitle,
        fromPolicyKind: node.policyKind,
        toPolicyKind: toPolicyKind,
        removedEdges: []
      )
    )
  }

  /// Resolve the policy kind to write when the visual kind changes. Preserve a
  /// custom binding whose kind string already matches the new visual kind's
  /// default; otherwise fall back to that default.
  private func policyKind(
    for kind: PolicyCanvasNodeKind,
    preserving existing: PolicyGraphNodeKind?
  ) -> PolicyGraphNodeKind {
    let defaultPolicyKind = policyNodeKind(for: kind)
    if let existing, existing.discriminator == defaultPolicyKind.discriminator {
      return existing
    }
    return defaultPolicyKind
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
  func commitSelectedNodePolicyKind(_ policyKind: PolicyGraphNodeKind) {
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

  func commitSelectedNodeAutomationBinding(
    _ binding: PolicyGraphAutomationBinding?
  ) {
    guard case .node(let id) = selection,
      let node = nodes.first(where: { $0.id == id })
    else {
      return
    }
    let previous = node.automationBinding
    guard previous != binding else {
      return
    }
    mutate(.setNodeAutomationBinding(id: id, from: previous, to: binding))
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
  // The remaining helpers reconstruct the selected node's policy-kind as a
  // faithful `PolicyGraphNodeKind` case. Each picker / stepper / text field
  // calls one of these; the helper reads any payload worth preserving out of
  // the current case, builds the new case, and routes through the funnel. The
  // funnel no-ops when the rebuilt case equals the current one.

  /// Commit a policy-action picker change.
  func commitSelectedPolicyAction(_ action: PolicyAction) {
    commitPolicyKindMutation { kind in
      kind = .actionGate(actions: [action])
    }
  }

  /// Commit a risk-threshold stepper change. Clamped to 0...100 to match the
  /// daemon contract. Preserves the field and reason codes when the node is
  /// already a risk classifier; otherwise seeds sensible defaults.
  func commitSelectedRiskThreshold(_ threshold: Int) {
    commitPolicyKindMutation { kind in
      let field: PolicyEvidenceField
      let highRisk: PolicyReasonCode
      let missing: PolicyReasonCode
      if case .riskClassifier(let existingField, _, let high, let miss) = kind {
        field = existingField
        highRisk = high
        missing = miss
      } else {
        field = .riskScore
        highRisk = .riskAboveThreshold
        missing = .humanRequired
      }
      kind = .riskClassifier(
        field: field,
        threshold: UInt8(min(100, max(0, threshold))),
        highRiskReasonCode: highRisk,
        missingReasonCode: missing
      )
    }
  }

  /// Commit an evidence-field picker change. On an `if_then_else` node this
  /// retargets the condition field; on any other kind it converts to an
  /// `evidence_check` seeded with one check on the picked field.
  func commitSelectedEvidenceField(_ field: PolicyEvidenceField) {
    commitPolicyKindMutation { kind in
      if case .ifThenElse(let condition) = kind {
        kind = .ifThenElse(
          PolicyIfThenElseCondition(field: field, predicate: condition.predicate)
        )
      } else {
        kind = .evidenceCheck(checks: [
          PolicyEvidenceCheck(
            field: field,
            pass: .isTrue,
            failReasonCode: .missingMergeEvidence,
            missingReasonCode: .missingMergeEvidence
          )
        ])
      }
    }
  }

  func commitSelectedConditionPredicate(_ predicate: PolicyEvidencePredicate) {
    commitPolicyKindMutation { kind in
      let field = kind.field ?? kind.checks.first?.field ?? .checksGreen
      kind = .ifThenElse(PolicyIfThenElseCondition(field: field, predicate: predicate))
    }
  }

  func commitSelectedWorkflow(_ workflow: String) {
    commitPolicyKindMutation { kind in
      kind = .trigger(workflow: workflow)
    }
  }

  func commitSelectedWorkflowID(_ workflowID: String) {
    commitPolicyKindMutation { kind in
      kind = .workflowEntry(PolicyWorkflowEntry(workflowId: workflowID))
    }
  }

  func commitSelectedActionID(_ actionID: String) {
    commitPolicyKindMutation { kind in
      kind = .actionStep(PolicyActionStep(actionId: actionID))
    }
  }

  /// Commit a reason-code text field change. Ignored when the text is not a
  /// valid daemon reason code. Rebuilds whichever gate or terminal owns a
  /// reason code; on a supervisor rule the single code replaces the code list.
  func commitSelectedReasonCode(_ reasonCode: String) {
    commitPolicyKindMutation { kind in
      guard let code = PolicyReasonCode(rawValue: reasonCode) else { return }
      switch kind {
      case .humanGate:
        kind = .humanGate(reasonCode: code)
      case .consensusGate:
        kind = .consensusGate(reasonCode: code)
      case .dryRunGate:
        kind = .dryRunGate(reasonCode: code)
      case .finish(let node):
        kind = .finish(PolicyFinishNode(decision: node.decision, reasonCode: code))
      case .supervisorRule(let decision, _):
        kind = .supervisorRule(decision: decision, reasonCodes: [code])
      default:
        break
      }
    }
  }

  /// Commit a gate-decision picker change. Ignored when the token is not a
  /// valid decision. A `finish` node keeps its terminal shape; anything else
  /// becomes a supervisor rule carrying the picked decision.
  func commitSelectedDecision(_ decision: String) {
    commitPolicyKindMutation { kind in
      guard let value = PolicyGraphDecision(rawValue: decision) else { return }
      if case .finish(let node) = kind {
        kind = .finish(PolicyFinishNode(decision: value, reasonCode: node.reasonCode))
      } else if case .supervisorRule(_, let codes) = kind {
        kind = .supervisorRule(decision: value, reasonCodes: codes)
      } else {
        kind = .supervisorRule(decision: value, reasonCodes: [.defaultAllow])
      }
    }
  }

  func commitSelectedWaitConditionKind(_ waitKind: PolicyWaitCondition.Kind) {
    commitPolicyKindMutation { kind in
      let resumeKey = waitResumeKey(from: kind)
      let existingWait = kind.wait
      let wait: PolicyWaitCondition
      switch waitKind {
      case .timer:
        wait = .timer(durationSeconds: existingWait?.durationSeconds ?? 900)
      case .event:
        wait = .event(eventKey: existingWait?.eventKey ?? "reviews.checks_passed")
      }
      kind = .waitStep(PolicyWaitStep(wait: wait, resumeKey: resumeKey))
    }
  }

  func commitSelectedWaitDuration(_ durationSeconds: Int) {
    commitPolicyKindMutation { kind in
      let resumeKey = waitResumeKey(from: kind)
      kind = .waitStep(
        PolicyWaitStep(
          wait: .timer(durationSeconds: UInt64(max(1, durationSeconds))), resumeKey: resumeKey)
      )
    }
  }

  func commitSelectedWaitEventKey(_ eventKey: String) {
    commitPolicyKindMutation { kind in
      let resumeKey = waitResumeKey(from: kind)
      kind = .waitStep(PolicyWaitStep(wait: .event(eventKey: eventKey), resumeKey: resumeKey))
    }
  }

  func commitSelectedResumeKey(_ resumeKey: String) {
    commitPolicyKindMutation { kind in
      let wait = kind.wait ?? .event(eventKey: "reviews.checks_passed")
      kind = .waitStep(PolicyWaitStep(wait: wait, resumeKey: resumeKey))
    }
  }

  func commitSelectedEventKey(_ eventKey: String) {
    commitPolicyKindMutation { kind in
      kind = .eventWait(PolicyEventWait(eventKey: eventKey))
    }
  }

  func commitSelectedHandoffKey(_ handoffKey: String) {
    commitPolicyKindMutation { kind in
      kind = .handoff(PolicyHandoffStep(handoffKey: handoffKey))
    }
  }

  /// The resume key to carry onto a rebuilt wait step: the current one when the
  /// node is already a wait step, otherwise the default.
  private func waitResumeKey(from kind: PolicyGraphNodeKind) -> String {
    if case .waitStep(let step) = kind {
      return defaultResumeKey(from: step.resumeKey)
    }
    return defaultResumeKey(from: nil)
  }

  /// Compose `setNodePolicyKind` from a closure that mutates a fresh copy of
  /// the selected node's policy-kind. Returns early when nothing about the
  /// kind changed (no-op pickers and refresh callbacks must not log a
  /// phantom undo step). Shared with the evidence-checks editor companion, so
  /// it is module-internal rather than file-private.
  func commitPolicyKindMutation(
    _ mutator: (inout PolicyGraphNodeKind) -> Void
  ) {
    guard case .node(let id) = selection,
      let node = nodes.first(where: { $0.id == id })
    else {
      return
    }
    let previous = node.policyKind ?? policyNodeKind(for: node.kind)
    var next = previous
    mutator(&next)
    guard previous != next else {
      return
    }
    mutate(.setNodePolicyKind(id: id, from: node.policyKind, to: next))
  }

  private func defaultResumeKey(from existing: String?) -> String {
    guard let existing, !existing.isEmpty else {
      return "checks-ready"
    }
    return existing
  }
}
