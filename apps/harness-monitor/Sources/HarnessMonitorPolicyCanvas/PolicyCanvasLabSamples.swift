import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms

/// A named, compiled-in sample policy for the Policy Canvas Lab picker.
///
/// Each sample is a self-contained `TaskBoardPolicyPipelineDocument` whose
/// nodes carry the right ports for their kind, whose edges connect real ports,
/// and whose groups list their member node ids. Layout seeds are rough
/// left-to-right positions; the lab force-arranges so seeds only need to be
/// sane. Complexity climbs from `minimal` to `extreme`.
public struct PolicyCanvasLabSample: Identifiable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let document: TaskBoardPolicyPipelineDocument

  public static func == (lhs: PolicyCanvasLabSample, rhs: PolicyCanvasLabSample) -> Bool {
    lhs.id == rhs.id
  }
}

/// The lab picker's bound selection. `.live` renders whatever policy the daemon
/// reports; `.sample` renders a compiled-in sample by id. Hashable so it can be
/// a `Picker` tag.
public enum PolicyCanvasLabSelection: Hashable, Sendable {
  case live
  case sample(String)
}

public enum PolicyCanvasLabSamples {
  /// Samples ordered simple -> extreme. The lab picker renders this order.
  public static let all: [PolicyCanvasLabSample] = [
    PolicyCanvasLabSample(id: "minimal", name: "Minimal", document: minimal),
    PolicyCanvasLabSample(id: "linear", name: "Linear", document: linear),
    PolicyCanvasLabSample(id: "branching", name: "Branching", document: branching),
    PolicyCanvasLabSample(id: "real-default", name: "Default", document: realDefault),
    PolicyCanvasLabSample(id: "multi-group", name: "Multi-group", document: multiGroup),
    PolicyCanvasLabSample(id: "extreme", name: "Extreme", document: extreme),
  ]

  private static let hiddenSamples: [PolicyCanvasLabSample] = [
    PolicyCanvasLabSample(id: "default-like", name: "Default-like", document: defaultLike)
  ]

  /// The sample the lab selects when no live policy is present.
  public static let defaultSelectionID = "real-default"

  public static func sample(id: String) -> PolicyCanvasLabSample? {
    all.first { $0.id == id } ?? hiddenSamples.first { $0.id == id }
  }
}

// MARK: - Minimal

extension PolicyCanvasLabSamples {
  private static let minimal: TaskBoardPolicyPipelineDocument = {
    let nodes = [
      node(
        "entry", "Workflow entry",
        TaskBoardPolicyPipelineNodeKind(kind: "workflow_entry", workflowId: "default-task"),
        group: "flow", outputs: ["out"]
      ),
      node(
        "finish", "Finish",
        TaskBoardPolicyPipelineNodeKind(
          kind: "finish", reasonCode: "policy_finished", decision: "allow"
        ),
        group: "flow", inputs: ["in"]
      ),
    ]
    let edges = [
      edge("e:entry-finish", "entry", "out", "finish", label: "done")
    ]
    let groups = [
      group("flow", "Flow", "#27c5f5", ["entry", "finish"])
    ]
    return document(nodes: nodes, edges: edges, groups: groups)
  }()
}

// MARK: - Linear

extension PolicyCanvasLabSamples {
  private static let linear: TaskBoardPolicyPipelineDocument = {
    let nodes = [
      node(
        "trigger", "Trigger",
        TaskBoardPolicyPipelineNodeKind(kind: "trigger", workflow: "default-task"),
        group: "intake", outputs: ["event"]
      ),
      node(
        "checks", "Checks green?",
        TaskBoardPolicyPipelineNodeKind(
          kind: "if_then_else",
          field: .checksGreen,
          predicate: TaskBoardPolicyEvidencePredicate(predicate: .isTrue)
        ),
        group: "intake", inputs: ["in"], outputs: ["then", "else"]
      ),
      node(
        "risk", "Risk acceptable?",
        TaskBoardPolicyPipelineNodeKind(
          kind: "if_then_else",
          field: .riskScore,
          predicate: TaskBoardPolicyEvidencePredicate(predicate: .isZero)
        ),
        group: "run", inputs: ["in"], outputs: ["then", "else"]
      ),
      node(
        "allow", "Allow",
        TaskBoardPolicyPipelineNodeKind(
          kind: "supervisor_rule", ruleId: "auto-allow",
          reasonCodes: ["auto_merge_allowed"], decision: "allow"
        ),
        group: "outcome", inputs: ["in"]
      ),
      node(
        "hold", "Hold for review",
        TaskBoardPolicyPipelineNodeKind(kind: "human_gate"),
        group: "outcome", inputs: ["in"]
      ),
      node(
        "deny", "Deny",
        TaskBoardPolicyPipelineNodeKind(
          kind: "supervisor_rule", ruleId: "checks-deny",
          reasonCodes: ["checks_not_green"], decision: "deny"
        ),
        group: "outcome", inputs: ["in"]
      ),
    ]
    let edges = [
      edge("e:trigger-checks", "trigger", "event", "checks", label: "evaluate"),
      edge("e:checks-risk", "checks", "then", "risk", label: "checks pass"),
      edge("e:checks-hold", "checks", "else", "hold", label: "needs review"),
      edge("e:risk-allow", "risk", "then", "allow", label: "low risk"),
      edge("e:risk-deny", "risk", "else", "deny", label: "high risk"),
    ]
    let groups = [
      group("intake", "Intake", "#27c5f5", ["trigger", "checks"]),
      group("run", "Run", "#c13adf", ["risk"]),
      group("outcome", "Outcome", "#24c55e", ["allow", "hold", "deny"]),
    ]
    return document(nodes: nodes, edges: edges, groups: groups)
  }()
}

// MARK: - Branching

extension PolicyCanvasLabSamples {
  private static let branching: TaskBoardPolicyPipelineDocument = {
    let nodes = [
      node(
        "router", "Action gate",
        TaskBoardPolicyPipelineNodeKind(
          kind: "action_gate",
          actions: [.mergePr, .submitReview, .mutateRepo, .spawnAgent]
        ),
        group: "entry", inputs: ["in"], outputs: ["merge", "review", "mutate", "default"]
      ),
      node(
        "merge-step", "Merge action",
        TaskBoardPolicyPipelineNodeKind(kind: "action_step", actionId: "reviews.merge"),
        group: "lanes", inputs: ["in"], outputs: ["out"]
      ),
      node(
        "review-step", "Review action",
        TaskBoardPolicyPipelineNodeKind(kind: "action_step", actionId: "reviews.submit"),
        group: "lanes", inputs: ["in"], outputs: ["out"]
      ),
      node(
        "mutate-step", "Mutate repo",
        TaskBoardPolicyPipelineNodeKind(kind: "dry_run_gate"),
        group: "lanes", inputs: ["in"]
      ),
      node(
        "default-step", "Default handler",
        TaskBoardPolicyPipelineNodeKind(kind: "handoff", handoffKey: "default-handler"),
        group: "lanes", inputs: ["in"], outputs: ["out"]
      ),
      // Shared fan-in collector: three lanes converge here, then it branches to
      // the three terminals.
      node(
        "collector", "Outcome evidence",
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
        group: "collect", inputs: ["in"], outputs: ["pass", "fail", "missing"]
      ),
      node(
        "human", "Human review",
        TaskBoardPolicyPipelineNodeKind(kind: "human_gate"),
        group: "collect", inputs: ["in"]
      ),
      node(
        "allow", "Allow",
        TaskBoardPolicyPipelineNodeKind(
          kind: "supervisor_rule", ruleId: "branch-allow",
          reasonCodes: ["auto_merge_allowed"], decision: "allow"
        ),
        group: "collect", inputs: ["in"]
      ),
      node(
        "deny", "Deny",
        TaskBoardPolicyPipelineNodeKind(
          kind: "supervisor_rule", ruleId: "branch-deny",
          reasonCodes: ["merge_denied"], decision: "deny"
        ),
        group: "collect", inputs: ["in"]
      ),
    ]
    let edges = [
      edge("e:r-merge", "router", "merge", "merge-step", label: "merge"),
      edge("e:r-review", "router", "review", "review-step", label: "review"),
      edge("e:r-mutate", "router", "mutate", "mutate-step", label: "mutate"),
      edge("e:r-default", "router", "default", "default-step", label: "default"),
      // Shared fan-in collector: three sources converge on one collector node.
      edge("e:merge-coll", "merge-step", "out", "collector", label: "merged"),
      edge("e:review-coll", "review-step", "out", "collector", label: "reviewed"),
      edge("e:default-coll", "default-step", "out", "collector", label: "handled"),
      edge("e:coll-allow", "collector", "pass", "allow", label: "approved"),
      edge("e:coll-deny", "collector", "fail", "deny", label: "rejected"),
      edge("e:coll-human", "collector", "missing", "human", label: "needs review"),
    ]
    let groups = [
      group("entry", "Routing", "#27c5f5", ["router"]),
      group(
        "lanes", "Action lanes", "#c13adf",
        ["merge-step", "review-step", "mutate-step", "default-step"]
      ),
      group(
        "collect", "Collectors", "#24c55e", ["collector", "human", "allow", "deny"]
      ),
    ]
    return document(nodes: nodes, edges: edges, groups: groups)
  }()
}
