import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms

// MARK: - Extreme stress variants

extension PolicyCanvasLabSamples {
  static let extremeBraid = extremeStressVariant(prefix: "xb", moduleCount: 3)
  static let extremeMatrix = extremeStressVariant(prefix: "xm", moduleCount: 4)
  static let extremeMesh = extremeStressVariant(prefix: "xs", moduleCount: 6)
  static let extremeLattice = extremeStressVariant(prefix: "xl", moduleCount: 10)
  static let extremeGalaxy = extremeStressVariant(prefix: "xg", moduleCount: 16)

  private static func extremeStressVariant(
    prefix: String,
    moduleCount: Int
  ) -> TaskBoardPolicyPipelineDocument {
    let modules = (1...moduleCount).map { index in
      extremeStressModule(prefix: prefix, index: index)
    }
    return document(
      nodes: modules.flatMap(\.nodes),
      edges: modules.flatMap(\.edges),
      groups: modules.flatMap(\.groups)
    )
  }

  private static func extremeStressModule(
    prefix: String,
    index: Int
  ) -> PolicyCanvasExtremeStressModule {
    let id = PolicyCanvasExtremeStressModuleID(prefix: prefix, index: index)
    let sourceGroup = id.group("sources")
    let decisionGroup = id.group("decisions")
    let outcomeGroup = id.group("outcomes")
    let nodes =
      extremeStressSourceNodes(id: id, group: sourceGroup)
      + extremeStressDecisionNodes(id: id, group: decisionGroup)
      + extremeStressOutcomeNodes(id: id, group: outcomeGroup)
    let groups = [
      group(
        sourceGroup,
        "Sources \(index)",
        "#27c5f5",
        [
          id.node("trigger"),
          id.node("entry"),
          id.node("screenshot"),
          id.node("ocr"),
          id.node("resolve-prs"),
          id.node("copy-prs"),
        ]
      ),
      group(
        decisionGroup,
        "Decision weave \(index)",
        "#c13adf",
        [
          id.node("action-gate"),
          id.node("evidence"),
          id.node("ifelse"),
          id.node("switch"),
          id.node("risk"),
          id.node("hub"),
          id.node("wait"),
          id.node("event-wait"),
          id.node("action"),
          id.node("handoff"),
        ]
      ),
      group(
        outcomeGroup,
        "Outcomes \(index)",
        "#24c55e",
        [
          id.node("human"),
          id.node("consensus"),
          id.node("dry-run"),
          id.node("allow"),
          id.node("deny"),
          id.node("finish"),
        ]
      ),
    ]
    return PolicyCanvasExtremeStressModule(
      nodes: nodes,
      edges: extremeStressEdges(id: id),
      groups: groups
    )
  }

  private static func extremeStressSourceNodes(
    id: PolicyCanvasExtremeStressModuleID,
    group: String
  ) -> [TaskBoardPolicyPipelineNode] {
    [
      node(
        id.node("trigger"), "Trigger \(id.index)",
        TaskBoardPolicyPipelineNodeKind(kind: "trigger", workflow: "stress-\(id.index)"),
        group: group, outputs: ["event"]
      ),
      node(
        id.node("entry"), "Workflow entry \(id.index)",
        TaskBoardPolicyPipelineNodeKind(
          kind: "workflow_entry",
          workflowId: "reviews_auto_stress_\(id.index)"
        ),
        group: group, outputs: ["out"]
      ),
      node(
        id.node("screenshot"), "Review screenshot \(id.index)",
        TaskBoardPolicyPipelineNodeKind(kind: "review_screenshot_paste"),
        group: group, outputs: ["image"]
      ),
      node(
        id.node("ocr"), "OCR screenshot \(id.index)",
        TaskBoardPolicyPipelineNodeKind(kind: "ocr_image"),
        group: group, inputs: ["in"], outputs: ["text"]
      ),
      node(
        id.node("resolve-prs"), "Resolve PRs \(id.index)",
        TaskBoardPolicyPipelineNodeKind(kind: "resolve_review_pull_requests"),
        group: group, inputs: ["in"], outputs: ["pull_requests"]
      ),
      node(
        id.node("copy-prs"), "Copy PR list \(id.index)",
        TaskBoardPolicyPipelineNodeKind(kind: "copy_review_pull_request_list"),
        group: group, inputs: ["in"]
      ),
    ]
  }

  private static func extremeStressDecisionNodes(
    id: PolicyCanvasExtremeStressModuleID,
    group: String
  ) -> [TaskBoardPolicyPipelineNode] {
    [
      node(
        id.node("action-gate"), "Action gate \(id.index)",
        TaskBoardPolicyPipelineNodeKind(
          kind: "action_gate",
          actions: TaskBoardPolicyAction.allCases
        ),
        group: group, inputs: ["in"],
        outputs: ["merge", "review", "mutate", "agent", "secret", "default"]
      ),
      node(
        id.node("evidence"), "Evidence braid \(id.index)",
        TaskBoardPolicyPipelineNodeKind(
          kind: "evidence_check",
          checks: [
            evidenceCheck(index: id.index, offset: 0),
            evidenceCheck(index: id.index, offset: 1),
            evidenceCheck(index: id.index, offset: 2),
          ]
        ),
        group: group, inputs: ["in"], outputs: ["pass", "fail", "missing"]
      ),
      node(
        id.node("ifelse"), "Boolean split \(id.index)",
        TaskBoardPolicyPipelineNodeKind(
          kind: "if_then_else",
          field: evidenceField(index: id.index, offset: 3),
          predicate: evidencePredicate(index: id.index, offset: 3)
        ),
        group: group, inputs: ["in"], outputs: ["then", "else"]
      ),
      node(
        id.node("switch"), "Ordered switch \(id.index)",
        TaskBoardPolicyPipelineNodeKind(
          kind: "switch",
          arms: [
            switchArm("case_open", index: id.index, offset: 4),
            switchArm("case_draft", index: id.index, offset: 5),
            switchArm("case_blocked", index: id.index, offset: 6),
          ]
        ),
        group: group, inputs: ["in"],
        outputs: ["case_open", "case_draft", "case_blocked", "default"]
      ),
      node(
        id.node("risk"), "Risk classifier \(id.index)",
        TaskBoardPolicyPipelineNodeKind(
          kind: "risk_classifier",
          field: .riskScore,
          threshold: UInt8(20 + (id.index * 7 % 70)),
          highRiskReasonCode: "stress_risk_high_\(id.index)",
          missingReasonCode: "stress_risk_missing_\(id.index)"
        ),
        group: group, inputs: ["in"], outputs: ["low_or_equal", "high", "missing"]
      ),
      node(
        id.node("hub"), "Payload hub \(id.index)",
        TaskBoardPolicyPipelineNodeKind(kind: "hub"),
        group: group, inputs: ["in"], outputs: ["out_1", "out_2", "out_3", "out_4"]
      ),
      node(
        id.node("wait"), "Timer wait \(id.index)",
        TaskBoardPolicyPipelineNodeKind(
          kind: "wait_step",
          wait: .timer(UInt64(60 + id.index * 15)),
          resumeKey: "stress-timer-\(id.index)"
        ),
        group: group, inputs: ["in"], outputs: ["out"]
      ),
      node(
        id.node("event-wait"), "Event wait \(id.index)",
        TaskBoardPolicyPipelineNodeKind(
          kind: "event_wait",
          eventKey: "reviews.stress.\(id.index)"
        ),
        group: group, inputs: ["in"], outputs: ["out"]
      ),
      node(
        id.node("action"), "Action step \(id.index)",
        TaskBoardPolicyPipelineNodeKind(
          kind: "action_step",
          actionId: "reviews.stress.action.\(id.index)"
        ),
        group: group, inputs: ["in"], outputs: ["out"]
      ),
      node(
        id.node("handoff"), "Handoff \(id.index)",
        TaskBoardPolicyPipelineNodeKind(
          kind: "handoff",
          handoffKey: "stress-handler-\(id.index)"
        ),
        group: group, inputs: ["in"], outputs: ["out"]
      ),
    ]
  }

  private static func extremeStressOutcomeNodes(
    id: PolicyCanvasExtremeStressModuleID,
    group: String
  ) -> [TaskBoardPolicyPipelineNode] {
    [
      node(
        id.node("human"), "Human gate \(id.index)",
        TaskBoardPolicyPipelineNodeKind(kind: "human_gate"),
        group: group, inputs: ["in"]
      ),
      node(
        id.node("consensus"), "Consensus \(id.index)",
        TaskBoardPolicyPipelineNodeKind(kind: "consensus_gate"),
        group: group, inputs: ["in"], outputs: ["out"]
      ),
      node(
        id.node("dry-run"), "Dry-run \(id.index)",
        TaskBoardPolicyPipelineNodeKind(kind: "dry_run_gate"),
        group: group, inputs: ["in"]
      ),
      node(
        id.node("allow"), "Allow \(id.index)",
        TaskBoardPolicyPipelineNodeKind(
          kind: "supervisor_rule",
          ruleId: "stress-allow-\(id.index)",
          reasonCodes: ["stress_auto_allow_\(id.index)"],
          decision: "allow"
        ),
        group: group, inputs: ["in"]
      ),
      node(
        id.node("deny"), "Deny \(id.index)",
        TaskBoardPolicyPipelineNodeKind(
          kind: "supervisor_rule",
          ruleId: "stress-deny-\(id.index)",
          reasonCodes: ["stress_denied_\(id.index)"],
          decision: "deny"
        ),
        group: group, inputs: ["in"]
      ),
      node(
        id.node("finish"), "Finish \(id.index)",
        TaskBoardPolicyPipelineNodeKind(
          kind: "finish",
          reasonCode: "stress_finished_\(id.index)",
          decision: "allow"
        ),
        group: group, inputs: ["in"]
      ),
    ]
  }

  private static func extremeStressEdges(
    id: PolicyCanvasExtremeStressModuleID
  ) -> [TaskBoardPolicyPipelineEdge] {
    [
      stressEdge(id, "trigger-gate", "trigger", "event", "action-gate", label: "event"),
      stressEdge(id, "entry-gate", "entry", "out", "action-gate", label: "entry"),
      stressEdge(id, "screen-ocr", "screenshot", "image", "ocr", label: "image"),
      stressEdge(id, "gate-evidence", "action-gate", "merge", "evidence", label: "merge"),
      stressEdge(id, "gate-switch", "action-gate", "review", "switch", label: "review"),
      stressEdge(id, "gate-dry", "action-gate", "mutate", "dry-run", label: "mutate"),
      stressEdge(id, "gate-hub", "action-gate", "agent", "hub", label: "agent"),
      stressEdge(id, "gate-human", "action-gate", "secret", "human", label: "secret"),
      stressEdge(id, "gate-handoff", "action-gate", "default", "handoff", label: "default"),
      stressEdge(id, "ocr-resolve", "ocr", "text", "resolve-prs", label: "recognized"),
      stressEdge(id, "resolve-copy", "resolve-prs", "pull_requests", "copy-prs", label: "resolved"),
      stressEdge(id, "evidence-if", "evidence", "pass", "ifelse", label: "pass"),
      stressEdge(id, "evidence-deny", "evidence", "fail", "deny", label: "fail"),
      stressEdge(id, "evidence-human", "evidence", "missing", "human", label: "missing"),
      stressEdge(id, "if-risk", "ifelse", "then", "risk", label: "then"),
      stressEdge(id, "if-consensus", "ifelse", "else", "consensus", label: "else"),
      stressEdge(id, "switch-wait", "switch", "case_open", "wait", label: "open"),
      stressEdge(id, "switch-human", "switch", "case_draft", "human", label: "draft"),
      stressEdge(id, "switch-deny", "switch", "case_blocked", "deny", label: "blocked"),
      stressEdge(id, "switch-event", "switch", "default", "event-wait", label: "default"),
      stressEdge(id, "risk-action", "risk", "low_or_equal", "action", label: "low"),
      stressEdge(id, "risk-consensus", "risk", "high", "consensus", label: "high"),
      stressEdge(id, "risk-human", "risk", "missing", "human", label: "missing"),
      stressEdge(id, "hub-action", "hub", "out_1", "action", label: "action"),
      stressEdge(id, "hub-wait", "hub", "out_2", "wait", label: "wait"),
      stressEdge(id, "hub-event", "hub", "out_3", "event-wait", label: "event"),
      stressEdge(id, "hub-resolve", "hub", "out_4", "resolve-prs", label: "resolve"),
      stressEdge(id, "wait-action", "wait", "out", "action", label: "resume"),
      stressEdge(id, "event-handoff", "event-wait", "out", "handoff", label: "observed"),
      stressEdge(id, "action-allow", "action", "out", "allow", label: "allow"),
      stressEdge(id, "handoff-finish", "handoff", "out", "finish", label: "finish"),
      stressEdge(id, "consensus-allow", "consensus", "out", "allow", label: "approved"),
      stressEdge(id, "evidence-wait", "evidence", "pass", "wait", label: "parallel wait"),
      stressEdge(id, "switch-risk", "switch", "default", "risk", label: "fallback risk"),
      stressEdge(id, "action-finish", "action", "out", "finish", label: "done"),
    ]
  }

  private static func stressEdge(
    _ id: PolicyCanvasExtremeStressModuleID,
    _ edgeID: String,
    _ fromNode: String,
    _ fromPort: String,
    _ toNode: String,
    label: String
  ) -> TaskBoardPolicyPipelineEdge {
    edge(
      id.edge(edgeID),
      id.node(fromNode),
      fromPort,
      id.node(toNode),
      label: label
    )
  }

  private static func evidenceCheck(
    index: Int,
    offset: Int
  ) -> TaskBoardPolicyEvidenceCheck {
    TaskBoardPolicyEvidenceCheck(
      field: evidenceField(index: index, offset: offset),
      pass: evidencePredicate(index: index, offset: offset),
      failReasonCode: "stress_fail_\(index)_\(offset)",
      missingReasonCode: "stress_missing_\(index)_\(offset)"
    )
  }

  private static func switchArm(
    _ port: String,
    index: Int,
    offset: Int
  ) -> TaskBoardPolicySwitchArm {
    TaskBoardPolicySwitchArm(
      port: port,
      field: evidenceField(index: index, offset: offset),
      predicate: evidencePredicate(index: index, offset: offset)
    )
  }

  private static func evidenceField(
    index: Int,
    offset: Int
  ) -> TaskBoardPolicyEvidenceField {
    stressEvidenceFields[(index + offset) % stressEvidenceFields.count]
  }

  private static func evidencePredicate(
    index: Int,
    offset: Int
  ) -> TaskBoardPolicyEvidencePredicate {
    TaskBoardPolicyEvidencePredicate(
      predicate: stressPredicateValues[(index + offset) % stressPredicateValues.count]
    )
  }

  private static let stressEvidenceFields: [TaskBoardPolicyEvidenceField] = [
    .checksGreen,
    .branchProtectionAllowsMerge,
    .reviewerVerdictApproved,
    .unresolvedRequestedChanges,
    .protectedPathTouched,
    .riskScore,
    .reviewIsOpen,
    .reviewIsDraft,
    .reviewReviewRequired,
    .reviewHasNoDecision,
    .reviewHasMergeConflicts,
    .reviewPolicyBlocked,
    .reviewViewerCanUpdate,
  ]

  private static let stressPredicateValues: [TaskBoardPolicyEvidencePredicateValue] = [
    .isTrue,
    .isFalse,
    .isZero,
    .isPositive,
    .isPresent,
    .isMissing,
  ]
}

private struct PolicyCanvasExtremeStressModule {
  let nodes: [TaskBoardPolicyPipelineNode]
  let edges: [TaskBoardPolicyPipelineEdge]
  let groups: [TaskBoardPolicyPipelineGroup]
}

private struct PolicyCanvasExtremeStressModuleID {
  let prefix: String
  let index: Int

  func group(_ suffix: String) -> String {
    "\(prefix)-m\(index)-\(suffix)"
  }

  func node(_ suffix: String) -> String {
    "\(prefix)-m\(index)-\(suffix)"
  }

  func edge(_ suffix: String) -> String {
    "\(prefix)e:m\(index)-\(suffix)"
  }
}
