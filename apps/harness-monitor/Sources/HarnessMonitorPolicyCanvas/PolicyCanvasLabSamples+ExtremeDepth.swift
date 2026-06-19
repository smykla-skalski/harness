import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import HarnessMonitorPolicyModels

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
      .evidenceCheck(checks: [
        PolicyEvidenceCheck(
          field: .unresolvedRequestedChanges,
          pass: .isZero,
          failReasonCode: .unresolvedRequestedChanges, missingReasonCode: .missingMergeEvidence
        ),
        PolicyEvidenceCheck(
          field: .protectedPathTouched,
          pass: .isFalse,
          failReasonCode: .protectedPathTouched, missingReasonCode: .missingMergeEvidence
        ),
      ]),
      group: "x-checks", inputs: ["in"], outputs: ["pass", "fail", "missing"]
    ),
    node(
      "x-switch2", "Verify switch",
      .switch(
        PolicySwitchNode(arms: [
          PolicySwitchArm(port: "case_a", field: .reviewReviewRequired, predicate: .isTrue),
          PolicySwitchArm(port: "case_b", field: .reviewViewerCanUpdate, predicate: .isTrue),
          PolicySwitchArm(port: "case_c", field: .reviewPolicyBlocked, predicate: .isFalse),
        ])),
      group: "x-checks", inputs: ["in"], outputs: ["case_a", "case_b", "case_c", "default"]
    ),
    node(
      "x-wait2", "Cooldown timer",
      .waitStep(PolicyWaitStep(wait: .timer(durationSeconds: 300), resumeKey: "cooldown")),
      group: "x-orchestration", inputs: ["in"], outputs: ["out"]
    ),
    node(
      "x-action2", "Post-merge action",
      .actionStep(PolicyActionStep(actionId: "reviews.notify")),
      group: "x-orchestration", inputs: ["in"], outputs: ["out"]
    ),
    node(
      "x-action3", "Finalize action",
      .actionStep(PolicyActionStep(actionId: "reviews.finalize")),
      group: "x-orchestration", inputs: ["in"], outputs: ["out"]
    ),
    node(
      "x-agent-evidence", "Agent evidence",
      .evidenceCheck(checks: [
        PolicyEvidenceCheck(
          field: .reviewHasNoDecision,
          pass: .isFalse,
          failReasonCode: .protectedPathTouched, missingReasonCode: .missingMergeEvidence
        )
      ]),
      group: "x-agent", inputs: ["in"], outputs: ["pass", "fail", "missing"]
    ),
    node(
      "x-agent-consensus", "Agent consensus",
      .consensusGate(reasonCode: .protectedPathTouched),
      group: "x-agent", inputs: ["in"]
    ),
    node(
      "x-human2", "Escalation gate",
      .humanGate(reasonCode: .humanRequired),
      group: "x-gates", inputs: ["in"]
    ),
    node(
      "x-deny2", "Block: verify",
      .supervisorRule(decision: .deny, reasonCodes: [.protectedPathTouched]),
      group: "x-terminals", inputs: ["in"]
    ),
    node(
      "x-allow2", "Allow: verify",
      .supervisorRule(decision: .allow, reasonCodes: [.autoMergeAllowed]),
      group: "x-terminals", inputs: ["in"]
    ),
    node(
      "x-finish2", "Finalize",
      .finish(PolicyFinishNode(decision: .allow, reasonCode: .autoMergeAllowed)),
      group: "x-terminals", inputs: ["in"]
    ),
  ]
}
