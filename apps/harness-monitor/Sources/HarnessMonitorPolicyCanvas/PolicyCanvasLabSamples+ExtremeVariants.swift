import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import HarnessMonitorPolicyModels

// MARK: - Extreme stress variants

extension PolicyCanvasLabSamples {
  static let extremeBraid = extremeStressVariant(prefix: "xb", moduleCount: 3)
  static let extremeMatrix = extremeStressVariant(prefix: "xm", moduleCount: 4)
  static let extremeMesh = extremeStressVariant(prefix: "xs", moduleCount: 6)
  static let extremeLattice = extremeStressVariant(prefix: "xl", moduleCount: 10)
  static let extremeGalaxy = extremeStressVariant(prefix: "xg", moduleCount: 16)

  private static func extremeStressVariant(
    prefix: String,
    moduleCount: Int
  ) -> PolicyPipelineDocument {
    let modules = (1...moduleCount).map { index in
      extremeStressModule(prefix: prefix, index: index)
    }
    return document(
      nodes: modules.flatMap(\.nodes),
      edges: modules.flatMap(\.edges),
      groups: modules.flatMap(\.groups)
    )
  }

  private static func extremeStressModule(
    prefix: String,
    index: Int
  ) -> PolicyCanvasExtremeStressModule {
    let id = PolicyCanvasExtremeStressModuleID(prefix: prefix, index: index)
    let sourceGroup = id.group("sources")
    let decisionGroup = id.group("decisions")
    let outcomeGroup = id.group("outcomes")
    let nodes =
      extremeStressSourceNodes(id: id, group: sourceGroup)
      + extremeStressDecisionNodes(id: id, group: decisionGroup)
      + extremeStressOutcomeNodes(id: id, group: outcomeGroup)
    let groups = [
      group(
        sourceGroup,
        "Sources \(index)",
        "#27c5f5",
        [
          id.node("trigger"),
          id.node("entry"),
          id.node("screenshot"),
          id.node("ocr"),
          id.node("resolve-prs"),
          id.node("copy-prs"),
        ]
      ),
      group(
        decisionGroup,
        "Decision weave \(index)",
        "#c13adf",
        [
          id.node("action-gate"),
          id.node("evidence"),
          id.node("ifelse"),
          id.node("switch"),
          id.node("risk"),
          id.node("hub"),
          id.node("wait"),
          id.node("event-wait"),
          id.node("action"),
          id.node("handoff"),
        ]
      ),
      group(
        outcomeGroup,
        "Outcomes \(index)",
        "#24c55e",
        [
          id.node("human"),
          id.node("consensus"),
          id.node("dry-run"),
          id.node("allow"),
          id.node("deny"),
          id.node("finish"),
        ]
      ),
    ]
    return PolicyCanvasExtremeStressModule(
      nodes: nodes,
      edges: extremeStressEdges(id: id),
      groups: groups
    )
  }

  private static func extremeStressSourceNodes(
    id: PolicyCanvasExtremeStressModuleID,
    group: String
  ) -> [PolicyPipelineNode] {
    [
      node(
        id.node("trigger"), "Trigger \(id.index)",
        .trigger(workflow: "stress-\(id.index)"),
        group: group, outputs: ["event"]
      ),
      node(
        id.node("entry"), "Workflow entry \(id.index)",
        .workflowEntry(PolicyWorkflowEntry(workflowId: "reviews_auto_stress_\(id.index)")),
        group: group, outputs: ["out"]
      ),
      node(
        id.node("screenshot"), "Review screenshot \(id.index)",
        .reviewScreenshotPaste,
        group: group, outputs: ["image"]
      ),
      node(
        id.node("ocr"), "OCR screenshot \(id.index)",
        .ocrImage,
        group: group, inputs: ["in"], outputs: ["text"]
      ),
      node(
        id.node("resolve-prs"), "Resolve PRs \(id.index)",
        .resolveReviewPullRequests,
        group: group, inputs: ["in"], outputs: ["pull_requests"]
      ),
      node(
        id.node("copy-prs"), "Copy PR list \(id.index)",
        .copyReviewPullRequestList,
        group: group, inputs: ["in"]
      ),
    ]
  }

  private static func extremeStressDecisionNodes(
    id: PolicyCanvasExtremeStressModuleID,
    group: String
  ) -> [PolicyPipelineNode] {
    [
      extremeStressActionGateNode(id: id, group: group),
      extremeStressEvidenceNode(id: id, group: group),
      node(
        id.node("ifelse"), "Boolean split \(id.index)",
        .ifThenElse(
          PolicyIfThenElseCondition(
            field: evidenceField(index: id.index, offset: 3),
            predicate: evidencePredicate(index: id.index, offset: 3)
          )),
        group: group, inputs: ["in"], outputs: ["then", "else"]
      ),
      extremeStressSwitchNode(id: id, group: group),
      node(
        id.node("risk"), "Risk classifier \(id.index)",
        .riskClassifier(
          field: .riskScore,
          threshold: UInt8(20 + (id.index * 7 % 70)),
          highRiskReasonCode: .riskAboveThreshold,
          missingReasonCode: .humanRequired
        ),
        group: group, inputs: ["in"], outputs: ["low_or_equal", "high", "missing"]
      ),
      node(
        id.node("hub"), "Payload hub \(id.index)",
        .hub,
        group: group, inputs: ["in"], outputs: ["out_1", "out_2", "out_3", "out_4"]
      ),
      node(
        id.node("wait"), "Timer wait \(id.index)",
        .waitStep(
          PolicyWaitStep(
            wait: .timer(durationSeconds: UInt64(60 + id.index * 15)),
            resumeKey: "stress-timer-\(id.index)"
          )),
        group: group, inputs: ["in"], outputs: ["out"]
      ),
      node(
        id.node("event-wait"), "Event wait \(id.index)",
        .eventWait(PolicyEventWait(eventKey: "reviews.stress.\(id.index)")),
        group: group, inputs: ["in"], outputs: ["out"]
      ),
      node(
        id.node("action"), "Action step \(id.index)",
        .actionStep(PolicyActionStep(actionId: "reviews.stress.action.\(id.index)")),
        group: group, inputs: ["in"], outputs: ["out"]
      ),
      node(
        id.node("handoff"), "Handoff \(id.index)",
        .handoff(PolicyHandoffStep(handoffKey: "stress-handler-\(id.index)")),
        group: group, inputs: ["in"], outputs: ["out"]
      ),
    ]
  }

  private static func extremeStressOutcomeNodes(
    id: PolicyCanvasExtremeStressModuleID,
    group: String
  ) -> [PolicyPipelineNode] {
    [
      node(
        id.node("human"), "Human gate \(id.index)",
        .humanGate(reasonCode: .humanRequired),
        group: group, inputs: ["in"]
      ),
      node(
        id.node("consensus"), "Consensus \(id.index)",
        .consensusGate(reasonCode: .protectedPathTouched),
        group: group, inputs: ["in"], outputs: ["out"]
      ),
      node(
        id.node("dry-run"), "Dry-run \(id.index)",
        .dryRunGate(reasonCode: .dryRunRequired),
        group: group, inputs: ["in"]
      ),
      node(
        id.node("allow"), "Allow \(id.index)",
        .supervisorRule(decision: .allow, reasonCodes: [.autoMergeAllowed]),
        group: group, inputs: ["in"]
      ),
      node(
        id.node("deny"), "Deny \(id.index)",
        .supervisorRule(decision: .deny, reasonCodes: [.checksNotGreen]),
        group: group, inputs: ["in"]
      ),
      node(
        id.node("finish"), "Finish \(id.index)",
        .finish(PolicyFinishNode(decision: .allow, reasonCode: .autoMergeAllowed)),
        group: group, inputs: ["in"]
      ),
    ]
  }

  private static func extremeStressEdges(
    id: PolicyCanvasExtremeStressModuleID
  ) -> [PolicyPipelineEdge] {
    [
      stressEdge(
        id, "trigger-gate", from: ("trigger", "event"), toNode: "action-gate", label: "event"),
      stressEdge(id, "entry-gate", from: ("entry", "out"), toNode: "action-gate", label: "entry"),
      stressEdge(id, "screen-ocr", from: ("screenshot", "image"), toNode: "ocr", label: "image"),
      stressEdge(
        id, "gate-evidence", from: ("action-gate", "merge"), toNode: "evidence", label: "merge"),
      stressEdge(
        id, "gate-switch", from: ("action-gate", "review"), toNode: "switch", label: "review"),
      stressEdge(
        id, "gate-dry", from: ("action-gate", "mutate"), toNode: "dry-run", label: "mutate"),
      stressEdge(id, "gate-hub", from: ("action-gate", "agent"), toNode: "hub", label: "agent"),
      stressEdge(
        id, "gate-human", from: ("action-gate", "secret"), toNode: "human", label: "secret"),
      stressEdge(
        id, "gate-handoff", from: ("action-gate", "default"), toNode: "handoff", label: "default"),
      stressEdge(
        id, "ocr-resolve", from: ("ocr", "text"), toNode: "resolve-prs", label: "recognized"),
      stressEdge(
        id, "resolve-copy", from: ("resolve-prs", "pull_requests"), toNode: "copy-prs",
        label: "resolved"),
      stressEdge(id, "evidence-if", from: ("evidence", "pass"), toNode: "ifelse", label: "pass"),
      stressEdge(id, "evidence-deny", from: ("evidence", "fail"), toNode: "deny", label: "fail"),
      stressEdge(
        id, "evidence-human", from: ("evidence", "missing"), toNode: "human", label: "missing"),
      stressEdge(id, "if-risk", from: ("ifelse", "then"), toNode: "risk", label: "then"),
      stressEdge(id, "if-consensus", from: ("ifelse", "else"), toNode: "consensus", label: "else"),
      stressEdge(id, "switch-wait", from: ("switch", "case_open"), toNode: "wait", label: "open"),
      stressEdge(
        id, "switch-human", from: ("switch", "case_draft"), toNode: "human", label: "draft"),
      stressEdge(
        id, "switch-deny", from: ("switch", "case_blocked"), toNode: "deny", label: "blocked"),
      stressEdge(
        id, "switch-event", from: ("switch", "default"), toNode: "event-wait", label: "default"),
      stressEdge(id, "risk-action", from: ("risk", "low_or_equal"), toNode: "action", label: "low"),
      stressEdge(id, "risk-consensus", from: ("risk", "high"), toNode: "consensus", label: "high"),
      stressEdge(id, "risk-human", from: ("risk", "missing"), toNode: "human", label: "missing"),
      stressEdge(id, "hub-action", from: ("hub", "out_1"), toNode: "action", label: "action"),
      stressEdge(id, "hub-wait", from: ("hub", "out_2"), toNode: "wait", label: "wait"),
      stressEdge(id, "hub-event", from: ("hub", "out_3"), toNode: "event-wait", label: "event"),
      stressEdge(
        id, "hub-resolve", from: ("hub", "out_4"), toNode: "resolve-prs", label: "resolve"),
      stressEdge(id, "wait-action", from: ("wait", "out"), toNode: "action", label: "resume"),
      stressEdge(
        id, "event-handoff", from: ("event-wait", "out"), toNode: "handoff", label: "observed"),
      stressEdge(id, "action-allow", from: ("action", "out"), toNode: "allow", label: "allow"),
      stressEdge(id, "handoff-finish", from: ("handoff", "out"), toNode: "finish", label: "finish"),
      stressEdge(
        id, "consensus-allow", from: ("consensus", "out"), toNode: "allow", label: "approved"),
      stressEdge(
        id, "evidence-wait", from: ("evidence", "pass"), toNode: "wait", label: "parallel wait"),
      stressEdge(
        id, "switch-risk", from: ("switch", "default"), toNode: "risk", label: "fallback risk"),
      stressEdge(id, "action-finish", from: ("action", "out"), toNode: "finish", label: "done"),
    ]
  }
}
