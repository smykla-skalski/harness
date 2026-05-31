import HarnessMonitorKit

// MARK: - Extreme

extension PolicyCanvasLabSamples {
  /// The stress sample: ~40 nodes across six groups with deep chains, three
  /// fan-out gates, three shared collectors, switches, two risk classifiers,
  /// human / consensus / dry-run gates, evidence checks, if/then/else, handoffs,
  /// and wait / event-wait steps, plus several cross-group long edges. It
  /// exercises every node kind in the catalog except `action_gate` (covered by
  /// the workflow-entry intake fan-out) - poke the layout engine hard.
  static let extreme: TaskBoardPolicyPipelineDocument = {
    document(
      nodes: extremeNodes, edges: extremeEdges, groups: extremeGroups
    )
  }()

  private static let extremeIntakeNodes = [
    node(
      "x-entry", "Workflow entry",
      TaskBoardPolicyPipelineNodeKind(kind: "workflow_entry", workflowId: "reviews_auto"),
      group: "x-intake", outputs: ["out"]
    ),
    node(
      "x-trigger", "Trigger",
      TaskBoardPolicyPipelineNodeKind(kind: "trigger", workflow: "default-task"),
      group: "x-intake", outputs: ["event"]
    ),
    node(
      "x-route", "Action gate",
      TaskBoardPolicyPipelineNodeKind(
        kind: "action_gate", actions: [.mergePr, .submitReview, .mutateRepo, .spawnAgent]
      ),
      group: "x-intake", inputs: ["in"],
      outputs: ["merge", "review", "mutate", "agent", "verify"]
    ),
  ]

  private static let extremeChecksNodes = [
    node(
      "x-evidence", "Merge evidence",
      TaskBoardPolicyPipelineNodeKind(
        kind: "evidence_check",
        checks: [
          TaskBoardPolicyEvidenceCheck(
            field: .checksGreen,
            pass: TaskBoardPolicyEvidencePredicate(predicate: .isTrue),
            failReasonCode: "checks_not_green", missingReasonCode: "checks_missing"
          ),
          TaskBoardPolicyEvidenceCheck(
            field: .branchProtectionAllowsMerge,
            pass: TaskBoardPolicyEvidencePredicate(predicate: .isTrue),
            failReasonCode: "branch_protection_blocked", missingReasonCode: "checks_missing"
          ),
        ]
      ),
      group: "x-checks", inputs: ["in"], outputs: ["pass", "fail", "missing"]
    ),
    node(
      "x-switch", "Review switch",
      TaskBoardPolicyPipelineNodeKind(
        kind: "switch",
        arms: [
          TaskBoardPolicySwitchArm(
            port: "case_open", field: .reviewIsOpen,
            predicate: TaskBoardPolicyEvidencePredicate(predicate: .isTrue)
          ),
          TaskBoardPolicySwitchArm(
            port: "case_draft", field: .reviewIsDraft,
            predicate: TaskBoardPolicyEvidencePredicate(predicate: .isTrue)
          ),
        ]
      ),
      group: "x-checks", inputs: ["in"], outputs: ["case_open", "case_draft", "default"]
    ),
    node(
      "x-ifelse", "Conflicts?",
      TaskBoardPolicyPipelineNodeKind(
        kind: "if_then_else", field: .reviewHasMergeConflicts,
        predicate: TaskBoardPolicyEvidencePredicate(predicate: .isFalse)
      ),
      group: "x-checks", inputs: ["in"], outputs: ["then", "else"]
    ),
    node(
      "x-risk-merge", "Merge risk",
      TaskBoardPolicyPipelineNodeKind(
        kind: "risk_classifier", field: .riskScore, threshold: 70,
        highRiskReasonCode: "merge_risk_high", missingReasonCode: "merge_risk_missing"
      ),
      group: "x-checks", inputs: ["in"], outputs: ["low_or_equal", "high", "missing"]
    ),
  ]

  private static let extremeOrchestrationNodes = [
    node(
      "x-wait", "Wait for checks",
      TaskBoardPolicyPipelineNodeKind(
        kind: "wait_step", wait: .event("reviews.checks_passed"), resumeKey: "checks-ready"
      ),
      group: "x-orchestration", inputs: ["in"], outputs: ["out"]
    ),
    node(
      "x-event", "Event wait",
      TaskBoardPolicyPipelineNodeKind(kind: "event_wait", eventKey: "reviews.deploy_ready"),
      group: "x-orchestration", inputs: ["in"], outputs: ["out"]
    ),
    node(
      "x-merge-step", "Merge action",
      TaskBoardPolicyPipelineNodeKind(kind: "action_step", actionId: "reviews.merge"),
      group: "x-orchestration", inputs: ["in"], outputs: ["out"]
    ),
    node(
      "x-handoff", "Handoff to deploy",
      TaskBoardPolicyPipelineNodeKind(kind: "handoff", handoffKey: "deploy-handler"),
      group: "x-orchestration", inputs: ["in"], outputs: ["out"]
    ),
  ]

  private static let extremeAgentNodes = [
    node(
      "x-agent-risk", "Agent risk",
      TaskBoardPolicyPipelineNodeKind(
        kind: "risk_classifier", field: .riskScore, threshold: 40,
        highRiskReasonCode: "agent_risk_high", missingReasonCode: "agent_risk_missing"
      ),
      group: "x-agent", inputs: ["in"], outputs: ["low_or_equal", "high", "missing"]
    ),
    node(
      "x-agent-step", "Spawn agent",
      TaskBoardPolicyPipelineNodeKind(kind: "action_step", actionId: "agents.spawn"),
      group: "x-agent", inputs: ["in"], outputs: ["out"]
    ),
    node(
      "x-agent-handoff", "Agent handoff",
      TaskBoardPolicyPipelineNodeKind(kind: "handoff", handoffKey: "agent-supervisor"),
      group: "x-agent", inputs: ["in"], outputs: ["out"]
    ),
  ]

  private static let extremeGateNodes = [
    node(
      "x-human", "Human gate",
      TaskBoardPolicyPipelineNodeKind(kind: "human_gate"),
      group: "x-gates", inputs: ["in"]
    ),
    node(
      "x-consensus", "Consensus gate",
      TaskBoardPolicyPipelineNodeKind(kind: "consensus_gate"),
      group: "x-gates", inputs: ["in"]
    ),
    node(
      "x-dryrun", "Dry-run gate",
      TaskBoardPolicyPipelineNodeKind(kind: "dry_run_gate"),
      group: "x-gates", inputs: ["in"]
    ),
  ]

  private static let extremeTerminalNodes = [
    node(
      "x-allow", "Allow merge",
      TaskBoardPolicyPipelineNodeKind(
        kind: "supervisor_rule", ruleId: "x-auto-merge",
        reasonCodes: ["auto_merge_allowed"], decision: "allow"
      ),
      group: "x-terminals", inputs: ["in"]
    ),
    node(
      "x-deny", "Deny merge",
      TaskBoardPolicyPipelineNodeKind(
        kind: "supervisor_rule", ruleId: "x-merge-deny",
        reasonCodes: ["merge_denied"], decision: "deny"
      ),
      group: "x-terminals", inputs: ["in"]
    ),
    node(
      "x-deploy", "Deploy",
      TaskBoardPolicyPipelineNodeKind(
        kind: "supervisor_rule", ruleId: "x-deploy",
        reasonCodes: ["deploy_allowed"], decision: "allow"
      ),
      group: "x-terminals", inputs: ["in"]
    ),
    node(
      "x-finish", "Finish",
      TaskBoardPolicyPipelineNodeKind(
        kind: "finish", reasonCode: "policy_finished", decision: "allow"
      ),
      group: "x-terminals", inputs: ["in"]
    ),
  ]

  static let extremeNodes: [TaskBoardPolicyPipelineNode] =
    extremeIntakeNodes + extremeChecksNodes + extremeOrchestrationNodes
    + extremeAgentNodes + extremeGateNodes + extremeTerminalNodes
    + extremeDepthNodes

  private static let extremeGroups = [
    group(
      "x-intake", "Intake", "#27c5f5", ["x-entry", "x-trigger", "x-route"]
    ),
    group(
      "x-checks", "Checks", "#c13adf",
      ["x-evidence", "x-switch", "x-ifelse", "x-risk-merge", "x-evidence2", "x-switch2"]
    ),
    group(
      "x-orchestration", "Orchestration", "#f5a524",
      ["x-wait", "x-event", "x-merge-step", "x-handoff", "x-wait2", "x-action2", "x-action3"]
    ),
    group(
      "x-agent", "Agent lane", "#9750dd",
      ["x-agent-risk", "x-agent-step", "x-agent-handoff", "x-agent-evidence", "x-agent-consensus"]
    ),
    group(
      "x-gates", "Gates", "#ff6f91", ["x-human", "x-consensus", "x-dryrun", "x-human2"]
    ),
    group(
      "x-terminals", "Terminals", "#24c55e",
      ["x-allow", "x-deny", "x-deploy", "x-finish", "x-deny2", "x-allow2", "x-finish2"]
    ),
  ]
}
