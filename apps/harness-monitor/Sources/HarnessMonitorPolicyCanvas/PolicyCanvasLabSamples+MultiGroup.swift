import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import HarnessMonitorPolicyModels

// MARK: - Multi-group

extension PolicyCanvasLabSamples {
  /// Two parallel branches from an intake gate - a review lane and a deploy
  /// lane - that both fan into shared collectors in an outcomes group. This is
  /// the shape that currently stresses the routing engine: every lane stage can
  /// short-circuit into one of four shared outcome terminals, so many long
  /// cross-group edges converge on the same nodes.
  static let multiGroup: TaskBoardPolicyPipelineDocument = {
    document(
      nodes: multiGroupNodes, edges: multiGroupEdges, groups: multiGroupGroups
    )
  }()

  private static let multiGroupIntakeNodes = [
    node(
      "mg-pre", "Pre-check",
      .ifThenElse(PolicyIfThenElseCondition(field: .reviewIsOpen, predicate: .isTrue)),
      group: "intake", inputs: ["in"], outputs: ["then", "else"]
    ),
    node(
      "intake", "Intake gate",
      .actionGate(actions: [.submitReview, .mergePr]),
      group: "intake", inputs: ["in"], outputs: ["review", "deploy"]
    ),
  ]

  private static let multiGroupReviewNodes = [
    node(
      "rv-switch", "Review switch",
      .switch(
        PolicySwitchNode(arms: [
          PolicySwitchArm(port: "pass", field: .reviewReviewRequired, predicate: .isTrue)
        ])),
      group: "review", inputs: ["in"], outputs: ["pass", "escalate", "default"]
    ),
    node(
      "rv-evidence", "Review evidence",
      .evidenceCheck(checks: [
        PolicyEvidenceCheck(
          field: .reviewerVerdictApproved,
          pass: .isTrue,
          failReasonCode: .reviewerNotApproved, missingReasonCode: .missingMergeEvidence
        )
      ]),
      group: "review", inputs: ["in"], outputs: ["pass", "fail", "missing"]
    ),
    node(
      "rv-ifelse", "Conflicts clear?",
      .ifThenElse(PolicyIfThenElseCondition(field: .reviewHasMergeConflicts, predicate: .isFalse)),
      group: "review", inputs: ["in"], outputs: ["then", "else"]
    ),
    node(
      "rv-consensus", "Consensus",
      .consensusGate(reasonCode: .protectedPathTouched),
      group: "review", inputs: ["in"], outputs: ["out"]
    ),
  ]

  private static let multiGroupDeployNodes = [
    node(
      "dp-risk", "Deploy risk",
      .riskClassifier(
        field: .riskScore, threshold: 60,
        highRiskReasonCode: .riskAboveThreshold, missingReasonCode: .humanRequired
      ),
      group: "deploy", inputs: ["in"], outputs: ["low_or_equal", "high", "missing"]
    ),
    node(
      "dp-wait", "Wait for checks",
      .waitStep(
        PolicyWaitStep(wait: .event(eventKey: "reviews.checks_passed"), resumeKey: "checks-ready")),
      group: "deploy", inputs: ["in"], outputs: ["out"]
    ),
    node(
      "dp-evidence", "Deploy evidence",
      .evidenceCheck(checks: [
        PolicyEvidenceCheck(
          field: .branchProtectionAllowsMerge,
          pass: .isTrue,
          failReasonCode: .branchProtectionBlocked, missingReasonCode: .missingMergeEvidence
        )
      ]),
      group: "deploy", inputs: ["in"], outputs: ["pass", "fail", "missing"]
    ),
    node(
      "dp-action", "Deploy action",
      .actionStep(PolicyActionStep(actionId: "reviews.deploy")),
      group: "deploy", inputs: ["in"], outputs: ["out"]
    ),
  ]

  private static let multiGroupOutcomeNodes = [
    node(
      "out-human", "Human gate",
      .humanGate(reasonCode: .humanRequired),
      group: "outcomes", inputs: ["in"]
    ),
    node(
      "out-allow", "Allow",
      .supervisorRule(decision: .allow, reasonCodes: [.autoMergeAllowed]),
      group: "outcomes", inputs: ["in"]
    ),
    node(
      "out-deny", "Deny",
      .supervisorRule(decision: .deny, reasonCodes: [.checksNotGreen]),
      group: "outcomes", inputs: ["in"]
    ),
    node(
      "out-finish", "Finish",
      .finish(PolicyFinishNode(decision: .allow, reasonCode: .autoMergeAllowed)),
      group: "outcomes", inputs: ["in"]
    ),
  ]

  private static let multiGroupNodes =
    multiGroupIntakeNodes + multiGroupReviewNodes
    + multiGroupDeployNodes + multiGroupOutcomeNodes

  private static let multiGroupEdges = [
    edge("e:pre-intake", "mg-pre", "then", "intake", label: "open"),
    edge("e:pre-deny", "mg-pre", "else", "out-deny", label: "closed"),
    edge("e:in-rv", "intake", "review", "rv-switch", label: "review"),
    edge("e:in-dp", "intake", "deploy", "dp-risk", label: "deploy"),
    // review lane
    edge("e:rvs-pass", "rv-switch", "pass", "rv-evidence", label: "review ok"),
    edge("e:rvs-esc", "rv-switch", "escalate", "out-human", label: "escalate"),
    edge("e:rvs-def", "rv-switch", "default", "out-deny", label: "reject"),
    edge("e:rv-pass", "rv-evidence", "pass", "rv-ifelse", label: "approved"),
    edge("e:rv-fail", "rv-evidence", "fail", "out-deny", label: "deny"),
    edge("e:rv-missing", "rv-evidence", "missing", "out-human", label: "missing"),
    edge("e:rv-then", "rv-ifelse", "then", "rv-consensus", label: "no conflicts"),
    edge("e:rv-else", "rv-ifelse", "else", "out-human", label: "conflicts"),
    edge("e:rv-allow", "rv-consensus", "out", "out-allow", label: "allow"),
    // deploy lane
    edge("e:dp-low", "dp-risk", "low_or_equal", "dp-wait", label: "low risk"),
    edge("e:dp-high", "dp-risk", "high", "out-deny", label: "deny"),
    edge("e:dp-missing", "dp-risk", "missing", "out-human", label: "missing"),
    edge("e:dp-wait-ev", "dp-wait", "out", "dp-evidence", label: "resumed"),
    edge("e:dp-pass", "dp-evidence", "pass", "dp-action", label: "branch ok"),
    edge("e:dp-fail", "dp-evidence", "fail", "out-deny", label: "deny"),
    edge("e:dp-ev-missing", "dp-evidence", "missing", "out-human", label: "missing"),
    edge("e:dp-finish", "dp-action", "out", "out-finish", label: "deployed"),
  ]

  private static let multiGroupGroups = [
    group("intake", "Intake", "#27c5f5", ["mg-pre", "intake"]),
    group(
      "review", "Review lane", "#c13adf", ["rv-switch", "rv-evidence", "rv-ifelse", "rv-consensus"]
    ),
    group(
      "deploy", "Deploy lane", "#f5a524", ["dp-risk", "dp-wait", "dp-evidence", "dp-action"]
    ),
    group(
      "outcomes", "Outcomes", "#24c55e", ["out-human", "out-allow", "out-deny", "out-finish"]
    ),
  ]
}
