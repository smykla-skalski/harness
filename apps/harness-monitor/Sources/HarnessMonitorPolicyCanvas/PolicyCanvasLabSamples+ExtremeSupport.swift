import HarnessMonitorKit
import HarnessMonitorPolicyModels

extension PolicyCanvasLabSamples {
  static func extremeStressActionGateNode(
    id: PolicyCanvasExtremeStressModuleID,
    group: String
  ) -> TaskBoardPolicyPipelineNode {
    node(
      id.node("action-gate"), "Action gate \(id.index)",
      .actionGate(actions: PolicyAction.allCases),
      group: group, inputs: ["in"],
      outputs: ["merge", "review", "mutate", "agent", "secret", "default"]
    )
  }

  static func extremeStressEvidenceNode(
    id: PolicyCanvasExtremeStressModuleID,
    group: String
  ) -> TaskBoardPolicyPipelineNode {
    node(
      id.node("evidence"), "Evidence braid \(id.index)",
      .evidenceCheck(checks: [
        evidenceCheck(index: id.index, offset: 0),
        evidenceCheck(index: id.index, offset: 1),
        evidenceCheck(index: id.index, offset: 2),
      ]),
      group: group, inputs: ["in"], outputs: ["pass", "fail", "missing"]
    )
  }

  static func extremeStressSwitchNode(
    id: PolicyCanvasExtremeStressModuleID,
    group: String
  ) -> TaskBoardPolicyPipelineNode {
    node(
      id.node("switch"), "Ordered switch \(id.index)",
      .switch(PolicySwitchNode(arms: [
        switchArm("case_open", index: id.index, offset: 4),
        switchArm("case_draft", index: id.index, offset: 5),
        switchArm("case_blocked", index: id.index, offset: 6),
      ])),
      group: group, inputs: ["in"],
      outputs: ["case_open", "case_draft", "case_blocked", "default"]
    )
  }

  static func stressEdge(
    _ id: PolicyCanvasExtremeStressModuleID,
    _ edgeID: String,
    from source: (node: String, port: String),
    toNode: String,
    label: String
  ) -> TaskBoardPolicyPipelineEdge {
    edge(
      id.edge(edgeID),
      id.node(source.node),
      source.port,
      id.node(toNode),
      label: label
    )
  }

  static func evidenceCheck(
    index: Int,
    offset: Int
  ) -> PolicyEvidenceCheck {
    PolicyEvidenceCheck(
      field: evidenceField(index: index, offset: offset),
      pass: evidencePredicate(index: index, offset: offset),
      failReasonCode: .checksNotGreen,
      missingReasonCode: .missingMergeEvidence
    )
  }

  static func switchArm(
    _ port: String,
    index: Int,
    offset: Int
  ) -> PolicySwitchArm {
    PolicySwitchArm(
      port: PolicyGraphPortId(port),
      field: evidenceField(index: index, offset: offset),
      predicate: evidencePredicate(index: index, offset: offset)
    )
  }

  static func evidenceField(
    index: Int,
    offset: Int
  ) -> PolicyEvidenceField {
    stressEvidenceFields[(index + offset) % stressEvidenceFields.count]
  }

  static func evidencePredicate(
    index: Int,
    offset: Int
  ) -> PolicyEvidencePredicate {
    stressPredicateValues[(index + offset) % stressPredicateValues.count]
  }

  static let stressEvidenceFields: [PolicyEvidenceField] = [
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

  static let stressPredicateValues: [PolicyEvidencePredicate] = [
    .isTrue,
    .isFalse,
    .isZero,
    .isPositive,
    .isPresent,
    .isMissing,
  ]
}

struct PolicyCanvasExtremeStressModule {
  let nodes: [TaskBoardPolicyPipelineNode]
  let edges: [TaskBoardPolicyPipelineEdge]
  let groups: [TaskBoardPolicyPipelineGroup]
}

struct PolicyCanvasExtremeStressModuleID {
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
