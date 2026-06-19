import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import HarnessMonitorPolicyModels

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
      .workflowEntry(PolicyWorkflowEntry(workflowId: "reviews_auto")),
      group: "x-intake", outputs: ["out"]
    ),
    node(
      "x-trigger", "Trigger",
      .trigger(workflow: "default-task"),
      group: "x-intake", outputs: ["event"]
    ),
    node(
      "x-route", "Action gate",
      .actionGate(actions: [.mergePr, .submitReview, .mutateRepo, .spawnAgent]),
      group: "x-intake", inputs: ["in"],
      outputs: ["merge", "review", "mutate", "agent", "verify"]
    ),
  ]

  private static let extremeChecksNodes = [
    node(
      "x-evidence", "Merge evidence",
      .evidenceCheck(checks: [
        PolicyEvidenceCheck(
          field: .checksGreen,
          pass: .isTrue,
          failReasonCode: .checksNotGreen, missingReasonCode: .missingMergeEvidence
        ),
        PolicyEvidenceCheck(
          field: .branchProtectionAllowsMerge,
          pass: .isTrue,
          failReasonCode: .branchProtectionBlocked, missingReasonCode: .missingMergeEvidence
        ),
      ]),
      group: "x-checks", inputs: ["in"], outputs: ["pass", "fail", "missing"]
    ),
    node(
      "x-switch", "Review switch",
      .switch(
        PolicySwitchNode(arms: [
          PolicySwitchArm(port: "case_open", field: .reviewIsOpen, predicate: .isTrue),
          PolicySwitchArm(port: "case_draft", field: .reviewIsDraft, predicate: .isTrue),
        ])),
      group: "x-checks", inputs: ["in"], outputs: ["case_open", "case_draft", "default"]
    ),
    node(
      "x-ifelse", "Conflicts?",
      .ifThenElse(PolicyIfThenElseCondition(field: .reviewHasMergeConflicts, predicate: .isFalse)),
      group: "x-checks", inputs: ["in"], outputs: ["then", "else"]
    ),
    node(
      "x-risk-merge", "Merge risk",
      .riskClassifier(
        field: .riskScore, threshold: 70,
        highRiskReasonCode: .riskAboveThreshold, missingReasonCode: .humanRequired
      ),
      group: "x-checks", inputs: ["in"], outputs: ["low_or_equal", "high", "missing"]
    ),
  ]

  private static let extremeOrchestrationNodes = [
    node(
      "x-wait", "Wait for checks",
      .waitStep(
        PolicyWaitStep(wait: .event(eventKey: "reviews.checks_passed"), resumeKey: "checks-ready")),
      group: "x-orchestration", inputs: ["in"], outputs: ["out"]
    ),
    node(
      "x-event", "Event wait",
      .eventWait(PolicyEventWait(eventKey: "reviews.deploy_ready")),
      group: "x-orchestration", inputs: ["in"], outputs: ["out"]
    ),
    node(
      "x-merge-step", "Merge action",
      .actionStep(PolicyActionStep(actionId: "reviews.merge")),
      group: "x-orchestration", inputs: ["in"], outputs: ["out"]
    ),
    node(
      "x-handoff", "Handoff to deploy",
      .handoff(PolicyHandoffStep(handoffKey: "deploy-handler")),
      group: "x-orchestration", inputs: ["in"], outputs: ["out"]
    ),
  ]

  private static let extremeAgentNodes = [
    node(
      "x-agent-risk", "Agent risk",
      .riskClassifier(
        field: .riskScore, threshold: 40,
        highRiskReasonCode: .riskAboveThreshold, missingReasonCode: .humanRequired
      ),
      group: "x-agent", inputs: ["in"], outputs: ["low_or_equal", "high", "missing"]
    ),
    node(
      "x-agent-step", "Spawn agent",
      .actionStep(PolicyActionStep(actionId: "agents.spawn")),
      group: "x-agent", inputs: ["in"], outputs: ["out"]
    ),
    node(
      "x-agent-handoff", "Agent handoff",
      .handoff(PolicyHandoffStep(handoffKey: "agent-supervisor")),
      group: "x-agent", inputs: ["in"], outputs: ["out"]
    ),
  ]

  private static let extremeGateNodes = [
    node(
      "x-human", "Human gate",
      .humanGate(reasonCode: .humanRequired),
      group: "x-gates", inputs: ["in"]
    ),
    node(
      "x-consensus", "Consensus gate",
      .consensusGate(reasonCode: .protectedPathTouched),
      group: "x-gates", inputs: ["in"]
    ),
    node(
      "x-dryrun", "Dry-run gate",
      .dryRunGate(reasonCode: .dryRunRequired),
      group: "x-gates", inputs: ["in"]
    ),
  ]

  private static let extremeTerminalNodes = [
    node(
      "x-allow", "Allow merge",
      .supervisorRule(decision: .allow, reasonCodes: [.autoMergeAllowed]),
      group: "x-terminals", inputs: ["in"]
    ),
    node(
      "x-deny", "Deny merge",
      .supervisorRule(decision: .deny, reasonCodes: [.checksNotGreen]),
      group: "x-terminals", inputs: ["in"]
    ),
    node(
      "x-deploy", "Deploy",
      .supervisorRule(decision: .allow, reasonCodes: [.autoMergeAllowed]),
      group: "x-terminals", inputs: ["in"]
    ),
    node(
      "x-finish", "Finish",
      .finish(PolicyFinishNode(decision: .allow, reasonCode: .autoMergeAllowed)),
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
