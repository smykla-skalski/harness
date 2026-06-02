import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms

// MARK: - Extreme edges

extension PolicyCanvasLabSamples {
  static let extremeEdges: [TaskBoardPolicyPipelineEdge] =
    extremeIntakeEdges + extremeChecksEdges + extremeLaneEdges + extremeCollectorEdges
    + extremeDepthEdges

  /// The verification sub-pipeline hanging off the intake gate's `verify` port.
  /// Several edges cross from intake / checks / agent groups into the terminals
  /// and gates groups, exercising long-edge routing.
  private static let extremeDepthEdges = [
    edge("xe:route-verify", "x-route", "verify", "x-evidence2", label: "verify"),
    edge("xe:ev2-pass", "x-evidence2", "pass", "x-switch2", label: "evidence ok"),
    edge("xe:ev2-fail", "x-evidence2", "fail", "x-deny2", label: "evidence fail"),
    edge("xe:ev2-missing", "x-evidence2", "missing", "x-human2", label: "missing"),
    edge("xe:sw2-a", "x-switch2", "case_a", "x-wait2", label: "review required"),
    edge("xe:sw2-b", "x-switch2", "case_b", "x-action2", label: "viewer update"),
    edge("xe:sw2-c", "x-switch2", "case_c", "x-agent-evidence", label: "agent path"),
    edge("xe:sw2-default", "x-switch2", "default", "x-action3", label: "finalize"),
    edge("xe:wait2-allow", "x-wait2", "out", "x-allow2", label: "cooled down"),
    edge("xe:action2-allow", "x-action2", "out", "x-allow2", label: "notified"),
    edge("xe:action3-finish", "x-action3", "out", "x-finish2", label: "finalized"),
    edge("xe:agent-ev-cons", "x-agent-evidence", "pass", "x-agent-consensus", label: "agent ok"),
    edge("xe:agent-ev-deny", "x-agent-evidence", "fail", "x-deny2", label: "agent blocked"),
    edge("xe:agent-ev-human", "x-agent-evidence", "missing", "x-human2", label: "missing"),
  ]

  /// Intake fan-in then a four-way fan-out into the check + agent lanes.
  private static let extremeIntakeEdges = [
    edge("xe:entry-route", "x-entry", "out", "x-route", label: "entry"),
    edge("xe:trigger-route", "x-trigger", "event", "x-route", label: "trigger"),
    edge("xe:route-merge", "x-route", "merge", "x-evidence", label: "merge"),
    edge("xe:route-review", "x-route", "review", "x-switch", label: "review"),
    edge("xe:route-mutate", "x-route", "mutate", "x-dryrun", label: "mutate"),
    edge("xe:route-agent", "x-route", "agent", "x-agent-risk", label: "agent"),
  ]

  /// Deep check chain: evidence -> ifelse -> risk, plus switch arms, with a
  /// long cross-group edge from the switch into orchestration.
  private static let extremeChecksEdges = [
    edge("xe:ev-pass", "x-evidence", "pass", "x-ifelse", label: "checks ok"),
    edge("xe:if-then", "x-ifelse", "then", "x-risk-merge", label: "no conflicts"),
    edge("xe:if-else", "x-ifelse", "else", "x-deny", label: "conflicts"),
    edge("xe:risk-low", "x-risk-merge", "low_or_equal", "x-wait", label: "low risk"),
    edge("xe:risk-high", "x-risk-merge", "high", "x-consensus", label: "high risk"),
    // switch arms: one stays in checks-adjacent flow, one is a long cross edge
    edge("xe:sw-open", "x-switch", "case_open", "x-event", label: "open"),
    edge("xe:sw-draft", "x-switch", "case_draft", "x-human", label: "draft"),
    edge("xe:sw-default", "x-switch", "default", "x-handoff", label: "other"),
  ]

  /// Orchestration + agent lane internal chains, with long cross-group edges
  /// into the terminals (which are pure sinks).
  private static let extremeLaneEdges = [
    // orchestration chain: both waits resume the merge step, which approves
    edge("xe:wait-merge", "x-wait", "out", "x-merge-step", label: "resumed"),
    edge("xe:event-merge", "x-event", "out", "x-merge-step", label: "ready"),
    edge("xe:merge-allow", "x-merge-step", "out", "x-allow", label: "merged"),
    // the review-switch default handoff drives the deploy terminal
    edge("xe:handoff-deploy", "x-handoff", "out", "x-deploy", label: "deploy"),
    // agent lane chain
    edge(
      "xe:agent-low", "x-agent-risk", "low_or_equal", "x-agent-step", label: "low risk"
    ),
    edge(
      "xe:agent-high", "x-agent-risk", "high", "x-consensus", label: "high risk"
    ),
    edge(
      "xe:agent-step-ho", "x-agent-step", "out", "x-agent-handoff", label: "spawned"
    ),
    // long cross-group edge: agent handoff finishes the workflow
    edge(
      "xe:agent-ho-finish", "x-agent-handoff", "out", "x-finish", label: "agent done"
    ),
  ]

  /// Three shared collectors, all pure sinks: the human gate (every missing
  /// rail), the deny terminal (every fail rail, folded into one merged red
  /// wire), and the dry-run gate. Several are long edges crossing from the
  /// checks / agent groups into the terminals and gates groups.
  private static let extremeCollectorEdges: [TaskBoardPolicyPipelineEdge] = {
    var edges: [TaskBoardPolicyPipelineEdge] = []
    // shared human-gate fan-in: every "missing" rail
    let missingSources = ["x-evidence", "x-risk-merge", "x-agent-risk"]
    for (index, source) in missingSources.enumerated() {
      edges.append(
        edge(
          "xe:missing-\(index)", source, "missing", "x-human", label: "missing evidence"
        )
      )
    }
    // shared deny fan-in: every "fail" rail (folds into one merged red wire)
    let failSources = [
      ("x-evidence", "checks_not_green"),
      ("x-evidence", "branch_protection_blocked"),
    ]
    for (index, entry) in failSources.enumerated() {
      edges.append(
        edge(
          "xe:fail-\(index)", entry.0, "fail", "x-deny", label: "evidence failure",
          condition: TaskBoardPolicyPipelineEdgeCondition(
            condition: "evidence_failure", reasonCode: entry.1
          )
        )
      )
    }
    return edges
  }()
}
