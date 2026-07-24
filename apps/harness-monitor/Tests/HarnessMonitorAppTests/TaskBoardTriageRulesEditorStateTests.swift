import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("Task board triage rules editor state")
struct TaskBoardTriageRulesEditorStateTests {
  @Test("Decoding malformed JSON returns nil instead of throwing")
  func decodingMalformedTextReturnsNil() {
    let state = TaskBoardTriageRulesEditorState()
    state.draftText = "not json"

    #expect(state.decodedCandidate() == nil)
  }

  @Test("Decoding a valid rule set round-trips through encodedText")
  func decodingValidTextRoundTrips() {
    let state = TaskBoardTriageRulesEditorState()
    guard let encoded = TaskBoardTriageRulesEditorState.encodedText(Self.ruleSet) else {
      Issue.record("expected the fixture rule set to encode")
      return
    }
    state.draftText = encoded

    #expect(state.decodedCandidate() == Self.ruleSet)
  }

  @Test("Applying a load with a draft populates the draft text and revision")
  func applyLoadWithDraftPopulatesFields() {
    let state = TaskBoardTriageRulesEditorState()
    let draft = TriageRuleSetDraft(
      rules: Self.ruleSet, revision: 3, actor: "operator-1", updatedAt: "2026-07-24T00:00:00Z"
    )
    let revisions = [
      TriageRuleSetRevisionSummary(
        revision: 2, schemaVersion: 1, ruleCount: 1, status: .active, actor: "operator-1",
        activatedAt: "2026-07-24T00:00:00Z")
    ]
    let audit = [
      TriageRuleSetAuditEntry(
        auditId: "audit-1", kind: .activated, revision: 2, actor: "operator-1",
        recordedAt: "2026-07-24T00:00:00Z")
    ]

    state.applyLoad(draft: draft, activeRevision: 2, revisions: revisions, audit: audit)

    #expect(state.draftRevision == 3)
    #expect(state.decodedCandidate() == Self.ruleSet)
    #expect(state.activeRevision == 2)
    #expect(state.revisions.map(\.revision) == [2])
    #expect(state.audit.map(\.auditId) == ["audit-1"])
    #expect(state.hasLoaded)
  }

  @Test("Applying a load with no draft clears the draft revision but keeps existing text")
  func applyLoadWithoutDraftClearsRevisionOnly() {
    let state = TaskBoardTriageRulesEditorState()
    state.draftText = "unsaved edits"
    state.draftRevision = 1

    state.applyLoad(draft: nil, activeRevision: nil, revisions: [], audit: [])

    #expect(state.draftRevision == nil)
    #expect(state.draftText == "unsaved edits")
    #expect(state.activeRevision == nil)
    #expect(state.hasLoaded)
  }

  private static var ruleSet: TriageRuleSetV1 {
    TriageRuleSetV1(
      schemaVersion: 1,
      rules: [
        TriageRule(
          id: "urgent-bugs",
          when: [.priorityEquals(priority: .critical)],
          outcome: TriageRuleOutcome(verdict: .todo, priorityAction: .setTo(priority: .critical))
        )
      ],
      defaultOutcome: TriageRuleOutcome(verdict: .undecided)
    )
  }
}
