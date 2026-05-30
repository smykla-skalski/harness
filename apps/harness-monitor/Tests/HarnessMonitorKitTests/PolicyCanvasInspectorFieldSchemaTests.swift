import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

/// The inspector renders whatever `PolicyCanvasInspectorFieldSchema` returns for
/// the selected node, so the schema is the contract that keeps the metadata-
/// driven inspector honest: a node kind's fields, order, and the wait-step
/// conditional are locked here rather than implied by a per-kind view builder.
@Suite("Policy canvas inspector field schema")
struct PolicyCanvasInspectorFieldSchemaTests {
  private func kind(
    _ kind: String,
    wait: TaskBoardPolicyWaitCondition? = nil,
    checks: [TaskBoardPolicyEvidenceCheck] = []
  ) -> TaskBoardPolicyPipelineNodeKind {
    TaskBoardPolicyPipelineNodeKind(kind: kind, checks: checks, wait: wait)
  }

  @Test("each node kind maps to its expected inspector fields")
  func fieldsPerKind() {
    let cases: [(String, [PolicyInspectorField])] = [
      ("trigger", [.workflow]),
      ("workflow_entry", [.workflowID]),
      ("action_gate", [.actionBinding]),
      ("action_step", [.actionID]),
      ("evidence_check", [.evidenceField]),
      ("risk_classifier", [.riskThreshold]),
      ("event_wait", [.eventKey]),
      ("handoff", [.handoffKey]),
      ("human_gate", [.reasonCode]),
      ("consensus_gate", [.reasonCode]),
      ("dry_run_gate", [.reasonCode]),
      ("supervisor_rule", [.ruleID, .gateDecision]),
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
      PolicyCanvasInspectorFieldSchema.fields(for: kind("wait_step", wait: .timer(900)))
        == [.waitKind, .waitDuration, .resumeKey]
    )
    #expect(
      PolicyCanvasInspectorFieldSchema.fields(for: kind("wait_step", wait: .event("x")))
        == [.waitKind, .waitEventKey, .resumeKey]
    )
    // A wait step with no condition yet defaults to the event branch.
    #expect(
      PolicyCanvasInspectorFieldSchema.fields(for: kind("wait_step"))
        == [.waitKind, .waitEventKey, .resumeKey]
    )
  }

  @Test("if then else exposes evidence and predicate inspector controls")
  func ifThenElseFields() {
    let fields = PolicyCanvasInspectorFieldSchema.fields(
      for: TaskBoardPolicyPipelineNodeKind(kind: "if_then_else", field: .checksGreen)
    )
    #expect(fields.map(\.accessibilityKey) == ["evidence-field", "condition-predicate"])
  }

  @Test("every catalog node kind exposes at least one inspector field")
  func everyCatalogKindHasFields() {
    for paletteKind in PolicyCanvasNodeKind.allCases {
      #expect(
        !PolicyCanvasInspectorFieldSchema.fields(for: kind(paletteKind.rawValue)).isEmpty,
        "no inspector fields for catalog node kind \(paletteKind.rawValue)"
      )
    }
  }

  @Test("an unknown node kind yields no inspector fields")
  func unknownKindHasNoFields() {
    #expect(PolicyCanvasInspectorFieldSchema.fields(for: kind("not_a_kind")).isEmpty)
  }

  @Test("field accessibility keys are unique")
  func accessibilityKeysAreUnique() {
    let keys = PolicyInspectorField.allCases.map(\.accessibilityKey)
    #expect(Set(keys).count == keys.count, "duplicate inspector field accessibility keys")
  }
}
