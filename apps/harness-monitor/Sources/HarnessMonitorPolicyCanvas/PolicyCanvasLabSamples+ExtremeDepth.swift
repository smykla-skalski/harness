import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms

// MARK: - Extreme depth nodes

/// A second verification sub-pipeline that hangs off the intake gate's `verify`
/// port, deepening the extreme sample to ~32 nodes. It adds a second evidence
/// check + switch fan-out, two orchestration steps, an agent evidence branch,
/// and three more terminals - widening every group and creating extra shared
/// fan-ins so the layout engine has long cross-group edges to route.
extension PolicyCanvasLabSamples {
  static let extremeDepthNodes: [TaskBoardPolicyPipelineNode] = [
    node(
      "x-evidence2", "Verify evidence",
      TaskBoardPolicyPipelineNodeKind(
        kind: "evidence_check",
        checks: [
          TaskBoardPolicyEvidenceCheck(
            field: .unresolvedRequestedChanges,
            pass: TaskBoardPolicyEvidencePredicate(predicate: .isZero),
            failReasonCode: "unresolved_requested_changes", missingReasonCode: "checks_missing"
          ),
          TaskBoardPolicyEvidenceCheck(
            field: .protectedPathTouched,
            pass: TaskBoardPolicyEvidencePredicate(predicate: .isFalse),
            failReasonCode: "protected_path_touched", missingReasonCode: "checks_missing"
          ),
        ]
      ),
      group: "x-checks", inputs: ["in"], outputs: ["pass", "fail", "missing"]
    ),
    node(
      "x-switch2", "Verify switch",
      TaskBoardPolicyPipelineNodeKind(
        kind: "switch",
        arms: [
          TaskBoardPolicySwitchArm(
            port: "case_a", field: .reviewReviewRequired,
            predicate: TaskBoardPolicyEvidencePredicate(predicate: .isTrue)
          ),
          TaskBoardPolicySwitchArm(
            port: "case_b", field: .reviewViewerCanUpdate,
            predicate: TaskBoardPolicyEvidencePredicate(predicate: .isTrue)
          ),
          TaskBoardPolicySwitchArm(
            port: "case_c", field: .reviewPolicyBlocked,
            predicate: TaskBoardPolicyEvidencePredicate(predicate: .isFalse)
          ),
        ]
      ),
      group: "x-checks", inputs: ["in"], outputs: ["case_a", "case_b", "case_c", "default"]
    ),
    node(
      "x-wait2", "Cooldown timer",
      TaskBoardPolicyPipelineNodeKind(kind: "wait_step", wait: .timer(300), resumeKey: "cooldown"),
      group: "x-orchestration", inputs: ["in"], outputs: ["out"]
    ),
    node(
      "x-action2", "Post-merge action",
      TaskBoardPolicyPipelineNodeKind(kind: "action_step", actionId: "reviews.notify"),
      group: "x-orchestration", inputs: ["in"], outputs: ["out"]
    ),
    node(
      "x-action3", "Finalize action",
      TaskBoardPolicyPipelineNodeKind(kind: "action_step", actionId: "reviews.finalize"),
      group: "x-orchestration", inputs: ["in"], outputs: ["out"]
    ),
    node(
      "x-agent-evidence", "Agent evidence",
      TaskBoardPolicyPipelineNodeKind(
        kind: "evidence_check",
        checks: [
          TaskBoardPolicyEvidenceCheck(
            field: .reviewHasNoDecision,
            pass: TaskBoardPolicyEvidencePredicate(predicate: .isFalse),
            failReasonCode: "agent_blocked", missingReasonCode: "checks_missing"
          )
        ]
      ),
      group: "x-agent", inputs: ["in"], outputs: ["pass", "fail", "missing"]
    ),
    node(
      "x-agent-consensus", "Agent consensus",
      TaskBoardPolicyPipelineNodeKind(kind: "consensus_gate"),
      group: "x-agent", inputs: ["in"]
    ),
    node(
      "x-human2", "Escalation gate",
      TaskBoardPolicyPipelineNodeKind(kind: "human_gate"),
      group: "x-gates", inputs: ["in"]
    ),
    node(
      "x-deny2", "Block: verify",
      TaskBoardPolicyPipelineNodeKind(
        kind: "supervisor_rule", ruleId: "x-verify-deny",
        reasonCodes: ["protected_path_touched"], decision: "deny"
      ),
      group: "x-terminals", inputs: ["in"]
    ),
    node(
      "x-allow2", "Allow: verify",
      TaskBoardPolicyPipelineNodeKind(
        kind: "supervisor_rule", ruleId: "x-verify-allow",
        reasonCodes: ["auto_merge_allowed"], decision: "allow"
      ),
      group: "x-terminals", inputs: ["in"]
    ),
    node(
      "x-finish2", "Finalize",
      TaskBoardPolicyPipelineNodeKind(
        kind: "finish", reasonCode: "policy_finished", decision: "allow"
      ),
      group: "x-terminals", inputs: ["in"]
    ),
  ]
}
