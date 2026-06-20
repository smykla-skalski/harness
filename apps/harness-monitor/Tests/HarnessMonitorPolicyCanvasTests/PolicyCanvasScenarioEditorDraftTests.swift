import Testing

@testable import HarnessMonitorPolicyCanvas
import HarnessMonitorPolicyModels

/// Phase 6 scenario editor: the pure draft <-> PolicyInput mapping. Optional
/// strings blank out to nil, tri-states cover the optional bools, and numbers
/// parse leniently, so a fully populated input round-trips byte-for-byte.
@Suite("Policy canvas scenario editor draft")
struct PolicyCanvasScenarioEditorDraftTests {
  @Test("A fully populated input round-trips through the draft")
  func roundTrip() {
    let input = PolicyInput(
      workflow: "merge-flow",
      action: .accessSecret,
      subject: PolicySubject(
        taskBoardItemId: "t1",
        sessionId: "s1",
        agentId: "a1",
        repository: "acme/app",
        branch: "main",
        pullRequest: "42",
        paths: ["src/a.swift", "src/b.swift"]
      ),
      evidence: PolicyEvidence(
        checksGreen: true,
        branchProtectionAllowsMerge: false,
        reviewerVerdictApproved: true,
        unresolvedRequestedChanges: 3,
        protectedPathTouched: false,
        riskScore: 200,
        reviewIsOpen: true
      )
    )

    let draft = PolicyCanvasScenarioEditorDraft(name: "Scenario A", input: input)
    #expect(draft.trimmedName == "Scenario A")
    #expect(draft.resolvedInput() == input)
  }

  @Test("Blank and invalid fields resolve to nil and empty paths")
  func blankFields() {
    var draft = PolicyCanvasScenarioEditorDraft()
    draft.name = "  Empty  "
    draft.action = .sync
    draft.repository = "   "
    draft.paths = "\n  \n"
    draft.riskScore = "not a number"

    let resolved = draft.resolvedInput()
    #expect(resolved.action == .sync)
    #expect(resolved.subject.repository == nil)
    #expect(resolved.subject.paths.isEmpty)
    #expect(resolved.evidence.riskScore == nil)
    #expect(resolved.evidence.checksGreen == nil)
    #expect(draft.trimmedName == "Empty")
  }

  @Test("Tri-state maps unset, yes, and no")
  func triState() {
    #expect(ScenarioTriState(nil) == .unset)
    #expect(ScenarioTriState(true) == .yes)
    #expect(ScenarioTriState(false) == .no)
    #expect(ScenarioTriState.unset.boolValue == nil)
    #expect(ScenarioTriState.yes.boolValue == true)
    #expect(ScenarioTriState.no.boolValue == false)
  }
}
