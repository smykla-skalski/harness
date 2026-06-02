import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms

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
      TaskBoardPolicyPipelineNodeKind(
        kind: "if_then_else", field: .reviewIsOpen,
        predicate: TaskBoardPolicyEvidencePredicate(predicate: .isTrue)
      ),
      group: "intake", inputs: ["in"], outputs: ["then", "else"]
    ),
    node(
      "intake", "Intake gate",
      TaskBoardPolicyPipelineNodeKind(kind: "action_gate", actions: [.submitReview, .mergePr]),
      group: "intake", inputs: ["in"], outputs: ["review", "deploy"]
    ),
  ]

  private static let multiGroupReviewNodes = [
    node(
      "rv-switch", "Review switch",
      TaskBoardPolicyPipelineNodeKind(
        kind: "switch",
        arms: [
          TaskBoardPolicySwitchArm(
            port: "pass", field: .reviewReviewRequired,
            predicate: TaskBoardPolicyEvidencePredicate(predicate: .isTrue)
          )
        ]
      ),
      group: "review", inputs: ["in"], outputs: ["pass", "escalate", "default"]
    ),
    node(
      "rv-evidence", "Review evidence",
      TaskBoardPolicyPipelineNodeKind(
        kind: "evidence_check",
        checks: [
          TaskBoardPolicyEvidenceCheck(
            field: .reviewerVerdictApproved,
            pass: TaskBoardPolicyEvidencePredicate(predicate: .isTrue),
            failReasonCode: "reviewer_not_approved", missingReasonCode: "checks_missing"
          )
        ]
      ),
      group: "review", inputs: ["in"], outputs: ["pass", "fail", "missing"]
    ),
    node(
      "rv-ifelse", "Conflicts clear?",
      TaskBoardPolicyPipelineNodeKind(
        kind: "if_then_else", field: .reviewHasMergeConflicts,
        predicate: TaskBoardPolicyEvidencePredicate(predicate: .isFalse)
      ),
      group: "review", inputs: ["in"], outputs: ["then", "else"]
    ),
    node(
      "rv-consensus", "Consensus",
      TaskBoardPolicyPipelineNodeKind(kind: "consensus_gate"),
      group: "review", inputs: ["in"], outputs: ["out"]
    ),
  ]

  private static let multiGroupDeployNodes = [
    node(
      "dp-risk", "Deploy risk",
      TaskBoardPolicyPipelineNodeKind(
        kind: "risk_classifier", field: .riskScore, threshold: 60,
        highRiskReasonCode: "merge_risk_high", missingReasonCode: "merge_risk_missing"
      ),
      group: "deploy", inputs: ["in"], outputs: ["low_or_equal", "high", "missing"]
    ),
    node(
      "dp-wait", "Wait for checks",
      TaskBoardPolicyPipelineNodeKind(
        kind: "wait_step", wait: .event("reviews.checks_passed"), resumeKey: "checks-ready"
      ),
      group: "deploy", inputs: ["in"], outputs: ["out"]
    ),
    node(
      "dp-evidence", "Deploy evidence",
      TaskBoardPolicyPipelineNodeKind(
        kind: "evidence_check",
        checks: [
          TaskBoardPolicyEvidenceCheck(
            field: .branchProtectionAllowsMerge,
            pass: TaskBoardPolicyEvidencePredicate(predicate: .isTrue),
            failReasonCode: "branch_protection_blocked", missingReasonCode: "checks_missing"
          )
        ]
      ),
      group: "deploy", inputs: ["in"], outputs: ["pass", "fail", "missing"]
    ),
    node(
      "dp-action", "Deploy action",
      TaskBoardPolicyPipelineNodeKind(kind: "action_step", actionId: "reviews.deploy"),
      group: "deploy", inputs: ["in"], outputs: ["out"]
    ),
  ]

  private static let multiGroupOutcomeNodes = [
    node(
      "out-human", "Human gate",
      TaskBoardPolicyPipelineNodeKind(kind: "human_gate"),
      group: "outcomes", inputs: ["in"]
    ),
    node(
      "out-allow", "Allow",
      TaskBoardPolicyPipelineNodeKind(
        kind: "supervisor_rule", ruleId: "mg-allow",
        reasonCodes: ["auto_merge_allowed"], decision: "allow"
      ),
      group: "outcomes", inputs: ["in"]
    ),
    node(
      "out-deny", "Deny",
      TaskBoardPolicyPipelineNodeKind(
        kind: "supervisor_rule", ruleId: "mg-deny",
        reasonCodes: ["merge_denied"], decision: "deny"
      ),
      group: "outcomes", inputs: ["in"]
    ),
    node(
      "out-finish", "Finish",
      TaskBoardPolicyPipelineNodeKind(
        kind: "finish", reasonCode: "policy_finished", decision: "allow"
      ),
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
