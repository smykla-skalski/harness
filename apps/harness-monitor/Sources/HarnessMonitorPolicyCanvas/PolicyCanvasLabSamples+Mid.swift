import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms

// MARK: - Default-like

extension PolicyCanvasLabSamples {
  /// Mirrors the real default policy shape: a switch chain where each check
  /// branches to its own deny terminal via a typed port and passes control on
  /// through a shared `pass` port, while every "missing" rail feeds ONE shared
  /// human-gate collector, ending in a risk classifier with low / high /
  /// missing outcomes.
  static let defaultLike: TaskBoardPolicyPipelineDocument = {
    let nodes = entryNodes + checkNodes + terminalNodes
    return document(
      nodes: nodes, edges: defaultLikeEdges, groups: defaultLikeGroups
    )
  }()

  private static let entryNodes = [
    node(
      "trigger", "Trigger",
      TaskBoardPolicyPipelineNodeKind(kind: "trigger", workflow: "default-task"),
      group: "entry", outputs: ["event"]
    )
  ]

  private static func switchNode(
    _ id: String, _ title: String, field: TaskBoardPolicyEvidenceField
  ) -> TaskBoardPolicyPipelineNode {
    node(
      id, title,
      TaskBoardPolicyPipelineNodeKind(
        kind: "switch",
        arms: [
          TaskBoardPolicySwitchArm(
            port: "pass", field: field,
            predicate: TaskBoardPolicyEvidencePredicate(predicate: .isTrue)
          )
        ]
      ),
      group: "checks", inputs: ["in"], outputs: ["pass", "fail", "missing"]
    )
  }

  private static let checkNodes = [
    switchNode("c-checks", "Checks green?", field: .checksGreen),
    switchNode("c-branch", "Branch protection", field: .branchProtectionAllowsMerge),
    switchNode("c-reviewer", "Reviewer approved", field: .reviewerVerdictApproved),
    switchNode("c-conflicts", "No conflicts?", field: .reviewHasMergeConflicts),
    switchNode("c-draft", "Not a draft?", field: .reviewIsDraft),
    switchNode("c-risk", "Risk gate", field: .riskScore),
  ]

  private static func denyNode(_ id: String, _ title: String, _ code: String)
    -> TaskBoardPolicyPipelineNode
  {
    node(
      id, title,
      TaskBoardPolicyPipelineNodeKind(
        kind: "supervisor_rule", ruleId: id, reasonCodes: [code], decision: "deny"
      ),
      group: "terminals", inputs: ["in"]
    )
  }

  private static let terminalNodes = [
    denyNode("d-checks", "Block: checks", "checks_not_green"),
    denyNode("d-branch", "Block: branch", "branch_protection_blocked"),
    denyNode("d-reviewer", "Block: reviewer", "reviewer_not_approved"),
    denyNode("d-conflicts", "Block: conflicts", "review_has_merge_conflicts"),
    denyNode("d-draft", "Block: draft", "review_is_draft"),
    node(
      "risk", "Risk classifier",
      TaskBoardPolicyPipelineNodeKind(
        kind: "risk_classifier", field: .riskScore, threshold: 70,
        highRiskReasonCode: "merge_risk_high", missingReasonCode: "merge_risk_missing"
      ),
      group: "terminals", inputs: ["in"], outputs: ["low_or_equal", "high", "missing"]
    ),
    node(
      "human", "Human gate",
      TaskBoardPolicyPipelineNodeKind(kind: "human_gate"),
      group: "terminals", inputs: ["in"]
    ),
    node(
      "allow", "Allow merge",
      TaskBoardPolicyPipelineNodeKind(
        kind: "supervisor_rule", ruleId: "auto-merge",
        reasonCodes: ["auto_merge_allowed"], decision: "allow"
      ),
      group: "terminals", inputs: ["in"]
    ),
    node(
      "high-risk", "High-risk preview",
      TaskBoardPolicyPipelineNodeKind(kind: "dry_run_gate"),
      group: "terminals", inputs: ["in"]
    ),
  ]

  private static let defaultLikeEdges: [TaskBoardPolicyPipelineEdge] = {
    var edges = [
      edge("e:t-c1", "trigger", "event", "c-checks", label: "evaluate"),
      // pass chain across the switch nodes
      edge("e:c1-c2", "c-checks", "pass", "c-branch", label: "checks ok"),
      edge("e:c2-c3", "c-branch", "pass", "c-reviewer", label: "branch ok"),
      edge("e:c3-c4", "c-reviewer", "pass", "c-conflicts", label: "reviewer ok"),
      edge("e:c4-c5", "c-conflicts", "pass", "c-draft", label: "no conflicts"),
      edge("e:c5-c6", "c-draft", "pass", "c-risk", label: "not draft"),
      edge("e:c6-risk", "c-risk", "pass", "risk", label: "evaluate risk"),
      // per-check deny terminals
      edge("e:c1-d", "c-checks", "fail", "d-checks", label: "fail"),
      edge("e:c2-d", "c-branch", "fail", "d-branch", label: "fail"),
      edge("e:c3-d", "c-reviewer", "fail", "d-reviewer", label: "fail"),
      edge("e:c4-d", "c-conflicts", "fail", "d-conflicts", label: "fail"),
      edge("e:c5-d", "c-draft", "fail", "d-draft", label: "fail"),
      // risk outcomes
      edge("e:risk-low", "risk", "low_or_equal", "allow", label: "low risk"),
      edge("e:risk-high", "risk", "high", "high-risk", label: "high risk"),
    ]
    // every "missing" rail feeds the one shared human gate
    let missingSources = [
      "c-checks", "c-branch", "c-reviewer", "c-conflicts", "c-draft", "c-risk", "risk",
    ]
    for (index, source) in missingSources.enumerated() {
      edges.append(
        edge(
          "e:missing-\(index)", source, "missing", "human", label: "missing evidence"
        )
      )
    }
    return edges
  }()

  private static let defaultLikeGroups = [
    group("entry", "Entry", "#27c5f5", ["trigger"]),
    group(
      "checks", "Checks", "#c13adf",
      ["c-checks", "c-branch", "c-reviewer", "c-conflicts", "c-draft", "c-risk"]
    ),
    group(
      "terminals", "Terminals", "#24c55e",
      [
        "d-checks", "d-branch", "d-reviewer", "d-conflicts", "d-draft",
        "risk", "human", "allow", "high-risk",
      ]
    ),
  ]
}
