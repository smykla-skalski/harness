import Foundation
import HarnessMonitorPolicyModels

extension PreviewFixtures {
  public static func policyCanvasPipelineDocument(
    mode: TaskBoardPolicyPipelineMode = .draft,
    revision: UInt64 = 1
  ) -> TaskBoardPolicyPipelineDocument {
    TaskBoardPolicyPipelineDocument(
      schemaVersion: 2,
      revision: revision,
      mode: mode,
      nodes: policyCanvasPipelineNodes,
      edges: policyCanvasPipelineEdges,
      groups: policyCanvasPipelineGroups,
      layout: TaskBoardPolicyPipelineLayout(
        nodes: policyCanvasPipelineNodes.enumerated().map { index, node in
          TaskBoardPolicyPipelineNodeLayout(
            nodeId: node.id,
            x: (index % 4) * 240,
            y: (index / 4) * 120
          )
        }
      ),
      policyTraceIds: ["trace-preview-policy-\(revision)"]
    )
  }

  public static func policyCanvasSimulation(
    for document: TaskBoardPolicyPipelineDocument
  ) -> TaskBoardPolicyPipelineSimulationResult {
    TaskBoardPolicyPipelineSimulationResult(
      revision: document.revision,
      traceId: "trace-preview-policy-simulation-\(document.revision)",
      simulatedAt: "2026-05-14T11:00:05Z",
      succeeded: true,
      validation: TaskBoardPolicyPipelineValidation(isValid: true),
      decisions: [
        TaskBoardPolicyPipelineSimulatedDecision(
          action: .mergePr,
          decision: TaskBoardPolicyDecision(
            decision: "require_human",
            reasonCode: "human_required",
            policyVersion: "task-board-policy-v2:rev-\(document.revision)"
          ),
          visitedNodeIds: [
            "action:router",
            "evidence:merge",
            "risk:merge",
            "human:unsafe-action",
          ],
          policyTraceIds: ["trace-preview-policy-simulation-\(document.revision)"]
        )
      ],
      policyTraceIds: ["trace-preview-policy-simulation-\(document.revision)"]
    )
  }

  public static func policyCanvasAudit(
    for document: TaskBoardPolicyPipelineDocument
  ) -> TaskBoardPolicyPipelineAuditSummary {
    TaskBoardPolicyPipelineAuditSummary(
      activeRevision: document.revision,
      mode: document.mode,
      latestTraceId: document.policyTraceIds.last,
      latestSimulation: nil,
      validation: TaskBoardPolicyPipelineValidation(isValid: true)
    )
  }
}

extension PreviewFixtures {
  private static let policyCanvasPipelineNodes: [TaskBoardPolicyPipelineNode] = [
    policyNode(
      id: "action:router",
      title: "Action gate",
      kind: .actionGate(actions: PolicyAction.allCases),
      groupID: "entry",
      inputs: ["in"],
      outputs: ["default", "mutate", "merge", "unsafe"]
    ),
    policyNode(
      id: "evidence:merge",
      title: "Merge evidence",
      kind: .evidenceCheck(checks: [
        PolicyEvidenceCheck(
          field: .checksGreen,
          pass: .isTrue,
          failReasonCode: .checksNotGreen,
          missingReasonCode: .missingMergeEvidence
        ),
        PolicyEvidenceCheck(
          field: .branchProtectionAllowsMerge,
          pass: .isTrue,
          failReasonCode: .branchProtectionBlocked,
          missingReasonCode: .missingMergeEvidence
        ),
        PolicyEvidenceCheck(
          field: .reviewerVerdictApproved,
          pass: .isTrue,
          failReasonCode: .reviewerNotApproved,
          missingReasonCode: .missingMergeEvidence
        ),
        PolicyEvidenceCheck(
          field: .unresolvedRequestedChanges,
          pass: .isZero,
          failReasonCode: .unresolvedRequestedChanges,
          missingReasonCode: .missingMergeEvidence
        ),
        PolicyEvidenceCheck(
          field: .protectedPathTouched,
          pass: .isFalse,
          failReasonCode: .protectedPathTouched,
          missingReasonCode: .missingMergeEvidence
        ),
      ]),
      groupID: "merge",
      inputs: ["in"],
      outputs: ["pass", "fail", "consensus", "missing"]
    ),
    policyNode(
      id: "risk:merge",
      title: "Merge risk",
      kind: .riskClassifier(
        field: .riskScore,
        threshold: 74,
        highRiskReasonCode: .riskAboveThreshold,
        missingReasonCode: .missingMergeEvidence
      ),
      groupID: "merge",
      inputs: ["in"],
      outputs: ["low_or_equal", "high", "missing"]
    ),
    policyNode(
      id: "supervisor:default-allow",
      title: "Default approval",
      kind: .supervisorRule(decision: .allow, reasonCodes: [.defaultAllow]),
      groupID: "terminal",
      inputs: ["in"]
    ),
    policyNode(
      id: "dry_run:mutate_repo",
      title: "Preview repo changes",
      kind: .dryRunGate(reasonCode: .dryRunRequired),
      groupID: "terminal",
      inputs: ["in"]
    ),
    policyNode(
      id: "human:unsafe-action",
      title: "Manual review for unsafe action",
      kind: .humanGate(reasonCode: .humanRequired),
      groupID: "terminal",
      inputs: ["in"]
    ),
    policyNode(
      id: "human:missing-merge-evidence",
      title: "Manual review for missing evidence",
      kind: .humanGate(reasonCode: .missingMergeEvidence),
      groupID: "terminal",
      inputs: ["in"]
    ),
    policyNode(
      id: "consensus:protected-path",
      title: "Protected path review",
      kind: .consensusGate(reasonCode: .protectedPathTouched),
      groupID: "terminal",
      inputs: ["in"]
    ),
    policyNode(
      id: "dry_run:high-risk-merge",
      title: "Preview high-risk merge",
      kind: .dryRunGate(reasonCode: .riskAboveThreshold),
      groupID: "terminal",
      inputs: ["in"]
    ),
    policyNode(
      id: "supervisor:merge-deny",
      title: "Block merge",
      kind: .supervisorRule(
        decision: .deny,
        reasonCodes: [
          .checksNotGreen,
          .branchProtectionBlocked,
          .reviewerNotApproved,
          .unresolvedRequestedChanges,
        ]
      ),
      groupID: "terminal",
      inputs: ["in"]
    ),
    policyNode(
      id: "supervisor:auto-merge",
      title: "Approve merge",
      kind: .supervisorRule(decision: .allow, reasonCodes: [.autoMergeAllowed]),
      groupID: "terminal",
      inputs: ["in"]
    ),
  ]

  private static let policyCanvasPipelineEdges: [TaskBoardPolicyPipelineEdge] = [
    policyEdge(
      "edge:default",
      "action:router",
      "default",
      "supervisor:default-allow",
      label: "default allow"
    ),
    policyEdge(
      "edge:mutate",
      "action:router",
      "mutate",
      "dry_run:mutate_repo",
      label: "preview repo changes"
    ),
    policyEdge(
      "edge:unsafe",
      "action:router",
      "unsafe",
      "human:unsafe-action",
      label: "needs manual review"
    ),
    policyEdge(
      "edge:merge",
      "action:router",
      "merge",
      "evidence:merge",
      label: "evaluate merge"
    ),
    policyEdge("edge:evidence-pass", "evidence:merge", "pass", "risk:merge", label: "checks pass"),
    policyEdge(
      "edge:evidence-consensus",
      "evidence:merge",
      "consensus",
      "consensus:protected-path",
      label: "protected path review"
    ),
    policyEdge(
      "edge:evidence-missing",
      "evidence:merge",
      "missing",
      "human:missing-merge-evidence",
      label: "missing evidence"
    ),
    policyEdge(
      "edge:risk-low",
      "risk:merge",
      "low_or_equal",
      "supervisor:auto-merge",
      label: "low risk"
    ),
    policyEdge(
      "edge:risk-high",
      "risk:merge",
      "high",
      "dry_run:high-risk-merge",
      label: "high risk preview"
    ),
    policyEdge(
      "edge:risk-missing",
      "risk:merge",
      "missing",
      "human:missing-merge-evidence",
      label: "missing risk signal"
    ),
    failEdge("edge:evidence-fail:checks-not-green", reasonCode: "checks_not_green"),
    failEdge(
      "edge:evidence-fail:branch-protection-blocked", reasonCode: "branch_protection_blocked"),
    failEdge("edge:evidence-fail:reviewer-not-approved", reasonCode: "reviewer_not_approved"),
    failEdge(
      "edge:evidence-fail:unresolved-requested-changes", reasonCode: "unresolved_requested_changes"),
  ]

  private static let policyCanvasPipelineGroups: [TaskBoardPolicyPipelineGroup] = [
    TaskBoardPolicyPipelineGroup(
      id: "entry",
      title: "Action routing",
      color: "#27c5f5",
      nodeIds: ["action:router"]
    ),
    TaskBoardPolicyPipelineGroup(
      id: "merge",
      title: "Merge checks",
      color: "#c13adf",
      nodeIds: ["evidence:merge", "risk:merge"]
    ),
    TaskBoardPolicyPipelineGroup(
      id: "terminal",
      title: "Terminal decisions",
      color: "#24c55e",
      nodeIds: policyCanvasPipelineNodes.filter { $0.groupId == "terminal" }.map(\.id)
    ),
  ]

  private static func policyNode(
    id: String,
    title: String,
    kind: PolicyGraphNodeKind,
    groupID: String,
    inputs: [String] = [],
    outputs: [String] = []
  ) -> TaskBoardPolicyPipelineNode {
    TaskBoardPolicyPipelineNode(
      id: PolicyGraphNodeId(id),
      title: title,
      kind: kind,
      groupId: PolicyGraphGroupId(groupID),
      inputs: inputs.map { TaskBoardPolicyPipelinePort(id: PolicyGraphPortId($0), title: $0) },
      outputs: outputs.map { TaskBoardPolicyPipelinePort(id: PolicyGraphPortId($0), title: $0) }
    )
  }

  private static func policyEdge(
    _ id: String,
    _ sourceNodeID: String,
    _ sourcePortID: String,
    _ targetNodeID: String,
    label: String? = nil
  ) -> TaskBoardPolicyPipelineEdge {
    TaskBoardPolicyPipelineEdge(
      id: PolicyGraphEdgeId(id),
      fromNodeId: PolicyGraphNodeId(sourceNodeID),
      fromPort: PolicyGraphPortId(sourcePortID),
      toNodeId: PolicyGraphNodeId(targetNodeID),
      toPort: "in",
      label: label ?? sourcePortID.replacingOccurrences(of: "_", with: " ")
    )
  }

  /// One reason-code branch of the evidence-failure fan-in into
  /// `supervisor:merge-deny`. The four share the source `fail` port, the target,
  /// the `"evidence failure"` label, and the `evidence_failure` condition, and
  /// differ only by `reason_code` - exactly the live policy's shape, so the
  /// canvas folds them into one red merged wire whose branches carry the reason
  /// codes a failure-type policy can route on.
  private static func failEdge(_ id: String, reasonCode: String) -> TaskBoardPolicyPipelineEdge {
    TaskBoardPolicyPipelineEdge(
      id: PolicyGraphEdgeId(id),
      fromNodeId: "evidence:merge",
      fromPort: "fail",
      toNodeId: "supervisor:merge-deny",
      toPort: "in",
      label: "evidence failure",
      condition: TaskBoardPolicyPipelineEdgeCondition(
        condition: "evidence_failure",
        reasonCode: reasonCode
      )
    )
  }
}
