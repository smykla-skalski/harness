import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms
import HarnessMonitorPolicyModels

/// The inspector renders whatever `PolicyCanvasInspectorFieldSchema` returns for
/// the selected node, so the schema is the contract that keeps the metadata-
/// driven inspector honest: a node kind's fields, order, and the wait-step
/// conditional are locked here rather than implied by a per-kind view builder.
@Suite("Policy canvas inspector field schema")
struct PolicyCanvasInspectorFieldSchemaTests {
  /// Build a representative `PolicyGraphNodeKind` whose discriminator equals the
  /// given token, so the schema (which switches on the discriminator) sees the
  /// same case the inspector would. `wait`/`checks` flow into the cases that
  /// carry them; every other token ignores them.
  private func kind(
    _ kind: String,
    wait: PolicyWaitCondition? = nil,
    checks: [PolicyEvidenceCheck] = []
  ) -> PolicyGraphNodeKind {
    switch kind {
    case "trigger": return .trigger(workflow: "default-task")
    case "workflow_entry": return .workflowEntry(PolicyWorkflowEntry(workflowId: "wf"))
    case "action_gate": return .actionGate(actions: [.spawnAgent])
    case "action_step": return .actionStep(PolicyActionStep(actionId: "a"))
    case "evidence_check":
      return .evidenceCheck(
        checks: checks.isEmpty
          ? [
            PolicyEvidenceCheck(
              field: .checksGreen, pass: .isTrue,
              failReasonCode: .checksNotGreen, missingReasonCode: .missingMergeEvidence
            )
          ]
          : checks
      )
    case "if_then_else":
      return .ifThenElse(PolicyIfThenElseCondition(field: .checksGreen, predicate: .isTrue))
    case "switch": return .switch(PolicySwitchNode(arms: []))
    case "risk_classifier":
      return .riskClassifier(
        field: .riskScore, threshold: 50,
        highRiskReasonCode: .riskAboveThreshold, missingReasonCode: .humanRequired
      )
    case "wait_step":
      return .waitStep(
        PolicyWaitStep(wait: wait ?? .event(eventKey: "reviews.checks_passed"), resumeKey: "r")
      )
    case "event_wait": return .eventWait(PolicyEventWait(eventKey: "e"))
    case "handoff": return .handoff(PolicyHandoffStep(handoffKey: "h"))
    case "hub": return .hub
    case "human_gate": return .humanGate(reasonCode: .humanRequired)
    case "consensus_gate": return .consensusGate(reasonCode: .protectedPathTouched)
    case "dry_run_gate": return .dryRunGate(reasonCode: .dryRunRequired)
    case "supervisor_rule": return .supervisorRule(decision: .allow, reasonCodes: [.defaultAllow])
    case "finish": return .finish(PolicyFinishNode(decision: .allow, reasonCode: .autoMergeAllowed))
    case "review_screenshot_paste": return .reviewScreenshotPaste
    case "ocr_image": return .ocrImage
    case "resolve_review_pull_requests": return .resolveReviewPullRequests
    case "copy_review_pull_request_list": return .copyReviewPullRequestList
    default: return .hub
    }
  }

  private static let fixedAutomationKinds: Set<String> = [
    "review_screenshot_paste",
    "ocr_image",
    "resolve_review_pull_requests",
    "copy_review_pull_request_list",
  ]

  /// Kinds that expose no kind-specific schema fields by design: the fixed
  /// automation kinds render through the automation inspector, and `hub` is a
  /// pure structural fan-out with nothing to configure. Both reach the inspector
  /// through paths other than the field schema, so an empty field list is the
  /// contract here, not a missing-wiring gap.
  private static let fieldlessKinds: Set<String> =
    fixedAutomationKinds.union(["hub"])

  @Test("each node kind maps to its expected inspector fields")
  func fieldsPerKind() {
    let cases: [(String, [PolicyInspectorField])] = [
      ("trigger", [.workflow]),
      ("workflow_entry", [.workflowID]),
      ("action_gate", [.actionBinding]),
      ("action_step", [.actionID]),
      ("evidence_check", [.evidenceChecks]),
      ("switch", [.switchCases]),
      ("risk_classifier", [.riskThreshold]),
      ("event_wait", [.eventKey]),
      ("handoff", [.handoffKey]),
      ("human_gate", [.reasonCode]),
      ("consensus_gate", [.reasonCode]),
      ("dry_run_gate", [.reasonCode]),
      ("supervisor_rule", [.gateDecision]),
      ("finish", [.finishDecision, .reasonCode]),
    ]
    for (id, expected) in cases {
      #expect(
        PolicyCanvasInspectorFieldSchema.fields(for: kind(id)) == expected,
        "field schema drift for node kind \(id)"
      )
    }
  }

  @Test("wait step swaps its middle field on the chosen wait kind")
  func waitStepConditionalField() {
    #expect(
      PolicyCanvasInspectorFieldSchema.fields(
        for: kind("wait_step", wait: .timer(durationSeconds: 900))
      ) == [.waitKind, .waitDuration, .resumeKey]
    )
    #expect(
      PolicyCanvasInspectorFieldSchema.fields(
        for: kind("wait_step", wait: .event(eventKey: "x"))
      ) == [.waitKind, .waitEventKey, .resumeKey]
    )
    // A wait step with no condition yet defaults to the event branch.
    #expect(
      PolicyCanvasInspectorFieldSchema.fields(for: kind("wait_step"))
        == [.waitKind, .waitEventKey, .resumeKey]
    )
  }

  @Test("if then else exposes evidence and predicate inspector controls")
  func ifThenElseFields() {
    let fields = PolicyCanvasInspectorFieldSchema.fields(for: kind("if_then_else"))
    #expect(fields.map(\.accessibilityKey) == ["evidence-field", "condition-predicate"])
  }

  @Test("switch exposes the switch cases inspector control")
  func switchFields() {
    let fields = PolicyCanvasInspectorFieldSchema.fields(for: kind("switch"))
    #expect(fields.map(\.accessibilityKey) == ["switch-cases"])
  }

  @Test("evidence predicate values include presence-aware options")
  func presenceAwarePredicateValuesExist() {
    #expect(PolicyEvidencePredicate.allCases.contains(.isPresent))
    #expect(PolicyEvidencePredicate.allCases.contains(.isMissing))
  }

  @Test("every catalog node kind maps to fields unless it is fieldless by design")
  func everyCatalogKindHasFields() {
    for paletteKind in PolicyCanvasNodeKind.allCases {
      let fields = PolicyCanvasInspectorFieldSchema.fields(for: kind(paletteKind.rawValue))
      if Self.fieldlessKinds.contains(paletteKind.rawValue) {
        #expect(
          fields.isEmpty,
          "fieldless catalog node kind \(paletteKind.rawValue) unexpectedly exposed fields"
        )
      } else {
        #expect(
          !fields.isEmpty,
          "no inspector fields for catalog node kind \(paletteKind.rawValue)"
        )
      }
    }
  }

  @Test("fixed automation node kinds use the automation inspector")
  func fixedAutomationKindsUseAutomationInspector() {
    for id in Self.fixedAutomationKinds {
      #expect(PolicyCanvasInspectorFieldSchema.fields(for: kind(id)).isEmpty)
    }
  }

  @Test("field accessibility keys are unique")
  func accessibilityKeysAreUnique() {
    let keys = PolicyInspectorField.allCases.map(\.accessibilityKey)
    #expect(Set(keys).count == keys.count, "duplicate inspector field accessibility keys")
  }
}
