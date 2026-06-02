import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

@Suite("Policy canvas edge kind - derivation and color")
struct PolicyCanvasEdgeKindTests {
  @Test("'always' maps to .flow")
  func alwaysIsFlow() {
    #expect(PolicyCanvasEdgeKind.derive(from: "always") == .flow)
  }

  @Test("Empty condition maps to .flow")
  func emptyIsFlow() {
    #expect(PolicyCanvasEdgeKind.derive(from: "") == .flow)
    #expect(PolicyCanvasEdgeKind.derive(from: "   ") == .flow)
  }

  @Test("Denied / error conditions map to .error")
  func deniedIsError() {
    #expect(PolicyCanvasEdgeKind.derive(from: "denied") == .error)
    #expect(PolicyCanvasEdgeKind.derive(from: "DENY") == .error)
    #expect(PolicyCanvasEdgeKind.derive(from: "request_failed") == .error)
    #expect(PolicyCanvasEdgeKind.derive(from: "policy_reject") == .error)
    #expect(PolicyCanvasEdgeKind.derive(from: "error_path") == .error)
  }

  @Test("Human-workflow conditions map to .control")
  func humanWorkflowMapsToControl() {
    #expect(PolicyCanvasEdgeKind.derive(from: "approved") == .control)
    #expect(PolicyCanvasEdgeKind.derive(from: "human_review") == .control)
    #expect(PolicyCanvasEdgeKind.derive(from: "audit_passed") == .control)
  }

  @Test("if then else branch conditions map to .control")
  func ifThenElseConditionsMapToControl() {
    #expect(PolicyCanvasEdgeKind.derive(from: "condition_true") == .control)
    #expect(PolicyCanvasEdgeKind.derive(from: "condition_false") == .control)
  }

  @Test("Generic non-error, non-human conditions default to .flow")
  func genericConditionsDefaultToFlow() {
    // Default fallback is `.flow`, not `.control`. The policy-flow domain
    // is mostly flow: forwarding rules without human-workflow or error
    // markers are not decision gates.
    #expect(PolicyCanvasEdgeKind.derive(from: "if x > 5") == .flow)
    #expect(PolicyCanvasEdgeKind.derive(from: "low risk") == .flow)
    #expect(PolicyCanvasEdgeKind.derive(from: "normalize") == .flow)
    #expect(PolicyCanvasEdgeKind.derive(from: "allow") == .flow)
  }

  @Test("Human-workflow tokens short-circuit error matching to .control")
  func humanWorkflowDoesNotMatchError() {
    // Prior substring heuristic landed these in `.error` because they
    // mention `denied`/`reject`/`fail`. The token-boundary classifier with
    // the human-workflow prefix short-circuit routes them to `.control`,
    // matching the document author's likely intent.
    #expect(PolicyCanvasEdgeKind.derive(from: "human_review_denied") == .control)
    #expect(PolicyCanvasEdgeKind.derive(from: "manual_approval_required") == .control)
    #expect(PolicyCanvasEdgeKind.derive(from: "reviewer_rejected") == .control)
    #expect(PolicyCanvasEdgeKind.derive(from: "audited_pass") == .control)
    #expect(PolicyCanvasEdgeKind.derive(from: "approver_denied") == .control)
  }

  @Test("Token-boundary matching ignores embedded substrings")
  func noSubstringFalsePositives() {
    // `predenial` should NOT match `deny`/`denied` because token splitting
    // produces ["predenial"], which is not in the error-marker set. The
    // prior substring heuristic would have classified this as `.error`;
    // the token-boundary classifier with `.flow` default routes these to
    // `.flow` instead - the intent is "no false positive into .error".
    #expect(PolicyCanvasEdgeKind.derive(from: "predenial") != .error)
    #expect(PolicyCanvasEdgeKind.derive(from: "errorless_check") != .error)
    #expect(PolicyCanvasEdgeKind.derive(from: "rejectable_step") != .error)
  }

  @Test("Explicit kind override bypasses derivation")
  func explicitOverrideBypassesDerivation() {
    let endpoint = PolicyCanvasPortEndpoint(nodeID: "n", portID: "p", kind: .output)
    let target = PolicyCanvasPortEndpoint(nodeID: "n2", portID: "p2", kind: .input)
    // Condition text would derive `.error`, but the explicit kind wins.
    let denied = PolicyCanvasEdge(
      id: "e",
      source: endpoint,
      target: target,
      label: "",
      condition: "denied",
      kind: .control
    )
    #expect(denied.kind == .control)
    // Condition text would derive `.flow`, but the explicit kind wins.
    let always = PolicyCanvasEdge(
      id: "e2",
      source: endpoint,
      target: target,
      label: "",
      condition: "always",
      kind: .error
    )
    #expect(always.kind == .error)
  }

  @Test("Each kind exposes a distinct accent color")
  func distinctAccentColors() {
    let colors = PolicyCanvasEdgeKind.allCases.map { $0.accentColor.description }
    #expect(Set(colors).count == PolicyCanvasEdgeKind.allCases.count)
  }

  @Test("Edge init derives kind from condition when not explicit")
  func initDerivesKind() {
    let endpoint = PolicyCanvasPortEndpoint(nodeID: "n", portID: "p", kind: .output)
    let target = PolicyCanvasPortEndpoint(nodeID: "n2", portID: "p2", kind: .input)
    let flow = PolicyCanvasEdge(id: "e1", source: endpoint, target: target, label: "")
    #expect(flow.kind == .flow)
    let denied = PolicyCanvasEdge(
      id: "e2",
      source: endpoint,
      target: target,
      label: "",
      condition: "denied"
    )
    #expect(denied.kind == .error)
    let explicit = PolicyCanvasEdge(
      id: "e3",
      source: endpoint,
      target: target,
      label: "",
      condition: "always",
      kind: .control
    )
    #expect(explicit.kind == .control)
  }
}
