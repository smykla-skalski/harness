import Testing

@testable import HarnessMonitorKit

@Suite("Preview harness client task board triage rules")
struct PreviewHarnessClientTaskBoardTriageRulesTests {
  @Test("Draft starts empty, saves, and enforces CAS on the expected revision")
  func draftSaveEnforcesCAS() async throws {
    let client = PreviewHarnessClient(fixtures: .taskBoardBoardOnly, isLaunchAgentInstalled: true)

    let empty = try await client.taskBoardTriageRulesDraft()
    #expect(empty.draft == nil)

    let firstSave = try await client.saveTaskBoardTriageRulesDraft(
      request: TaskBoardSaveTriageRulesDraftRequest(
        rules: Self.ruleSet, expectedRevision: nil, actor: "operator-1")
    )
    #expect(firstSave.persisted)
    #expect(firstSave.revision == 1)

    let staleSave = try await client.saveTaskBoardTriageRulesDraft(
      request: TaskBoardSaveTriageRulesDraftRequest(
        rules: Self.ruleSet, expectedRevision: nil, actor: "operator-1")
    )
    #expect(!staleSave.persisted)
    #expect(staleSave.revision == 1)

    let secondSave = try await client.saveTaskBoardTriageRulesDraft(
      request: TaskBoardSaveTriageRulesDraftRequest(
        rules: Self.ruleSet, expectedRevision: 1, actor: "operator-1")
    )
    #expect(secondSave.persisted)
    #expect(secondSave.revision == 2)
  }

  @Test("Draft save rejects a malformed candidate without persisting")
  func draftSaveRejectsMalformedCandidate() async throws {
    let client = PreviewHarnessClient(fixtures: .taskBoardBoardOnly, isLaunchAgentInstalled: true)
    let malformed = TriageRuleSetV1(
      schemaVersion: 1,
      rules: [
        TriageRule(id: "dup", outcome: TriageRuleOutcome(verdict: .todo)),
        TriageRule(id: "dup", outcome: TriageRuleOutcome(verdict: .undecided)),
        TriageRule(id: "  ", outcome: TriageRuleOutcome(verdict: .todo)),
      ],
      defaultOutcome: TriageRuleOutcome(verdict: .undecided)
    )

    let result = try await client.saveTaskBoardTriageRulesDraft(
      request: TaskBoardSaveTriageRulesDraftRequest(
        rules: malformed, expectedRevision: nil, actor: "operator-1")
    )

    #expect(!result.persisted)
    #expect(result.validation.issues.contains(.duplicateRuleId(ruleId: "dup")))
    #expect(result.validation.issues.contains(.malformedRuleId(index: 2)))
    let draft = try await client.taskBoardTriageRulesDraft()
    #expect(draft.draft == nil)
  }

  @Test("Preview evaluates first-match-wins and reports the matched rule id")
  func previewEvaluatesFirstMatchWins() async throws {
    let client = PreviewHarnessClient(fixtures: .taskBoardBoardOnly, isLaunchAgentInstalled: true)
    let critical = try await client.createTaskBoardItem(
      request: TaskBoardCreateItemRequest(
        title: "Critical bug", body: "", priority: .critical, agentMode: .headless,
        tags: ["kind/bug"])
    )
    let quiet = try await client.createTaskBoardItem(
      request: TaskBoardCreateItemRequest(
        title: "Quiet task", body: "", priority: .low, agentMode: .headless, tags: [])
    )

    let result = try await client.previewTaskBoardTriageRules(
      request: TaskBoardPreviewTriageRulesRequest(rules: Self.ruleSet)
    )

    let criticalEntry = try #require(result.diff.first { $0.itemId == critical.id })
    let quietEntry = try #require(result.diff.first { $0.itemId == quiet.id })
    #expect(criticalEntry.candidateVerdict == .todo)
    #expect(criticalEntry.candidateMatchedRuleId == "urgent-bugs")
    #expect(criticalEntry.governsPlacementChange)
    #expect(quietEntry.candidateVerdict == .undecided)
    #expect(quietEntry.candidateMatchedRuleId == nil)
  }

  @Test("Preview never mutates the board and rejects an invalid candidate up front")
  func previewRejectsInvalidCandidateWithoutMutating() async throws {
    let client = PreviewHarnessClient(fixtures: .taskBoardBoardOnly, isLaunchAgentInstalled: true)
    let invalid = TriageRuleSetV1(
      schemaVersion: 99, rules: [], defaultOutcome: TriageRuleOutcome(verdict: .undecided)
    )

    let result = try await client.previewTaskBoardTriageRules(
      request: TaskBoardPreviewTriageRulesRequest(rules: invalid)
    )

    #expect(result.diff.isEmpty)
    #expect(result.validation.issues == [.unsupportedSchemaVersion(expected: 1, actual: 99)])
  }

  @Test("Activation records a revision, supersedes the prior one, and audits both")
  func activationRecordsRevisionAndSupersedesPrior() async throws {
    let client = PreviewHarnessClient(fixtures: .taskBoardBoardOnly, isLaunchAgentInstalled: true)

    let first = try await client.activateTaskBoardTriageRules(
      request: TaskBoardActivateTriageRulesRequest(
        rules: Self.ruleSet, expectedActiveRevision: nil, actor: "operator-1")
    )
    #expect(first.activated)
    #expect(first.revision == 1)

    let second = try await client.activateTaskBoardTriageRules(
      request: TaskBoardActivateTriageRulesRequest(
        rules: Self.ruleSet, expectedActiveRevision: 1, actor: "operator-1")
    )
    #expect(second.activated)
    #expect(second.revision == 2)

    let revisions = try await client.taskBoardTriageRulesRevisions(limit: nil)
    #expect(revisions.revisions.count == 2)
    let active = try #require(revisions.revisions.first { $0.status == .active })
    let superseded = try #require(revisions.revisions.first { $0.status == .superseded })
    #expect(active.revision == 2)
    #expect(superseded.revision == 1)
    #expect(superseded.supersededAt != nil)

    let audit = try await client.taskBoardTriageRulesAudit(limit: nil)
    #expect(audit.audit.filter { $0.kind == .activated }.count == 2)
  }

  @Test("A stale expected active revision is rejected and audited without changing state")
  func activationRejectsStaleExpectedRevision() async throws {
    let client = PreviewHarnessClient(fixtures: .taskBoardBoardOnly, isLaunchAgentInstalled: true)
    _ = try await client.activateTaskBoardTriageRules(
      request: TaskBoardActivateTriageRulesRequest(
        rules: Self.ruleSet, expectedActiveRevision: nil, actor: "operator-1")
    )

    let result = try await client.activateTaskBoardTriageRules(
      request: TaskBoardActivateTriageRulesRequest(
        rules: Self.ruleSet, expectedActiveRevision: nil, actor: "operator-1")
    )

    #expect(!result.activated)
    #expect(result.revision == 1)
    let revisions = try await client.taskBoardTriageRulesRevisions(limit: nil)
    #expect(revisions.revisions.count == 1)
  }

  @Test("Deactivating reverts to the BuiltInV1 default and records a deactivated audit entry")
  func deactivationRevertsToDefault() async throws {
    let client = PreviewHarnessClient(fixtures: .taskBoardBoardOnly, isLaunchAgentInstalled: true)
    let activated = try await client.activateTaskBoardTriageRules(
      request: TaskBoardActivateTriageRulesRequest(
        rules: Self.ruleSet, expectedActiveRevision: nil, actor: "operator-1")
    )

    let result = try await client.activateTaskBoardTriageRules(
      request: TaskBoardActivateTriageRulesRequest(
        rules: nil, expectedActiveRevision: activated.revision, actor: "operator-1")
    )

    #expect(result.activated)
    #expect(result.revision == nil)
    let audit = try await client.taskBoardTriageRulesAudit(limit: nil)
    #expect(audit.audit.first?.kind == .deactivated)
  }

  private static var ruleSet: TriageRuleSetV1 {
    TriageRuleSetV1(
      schemaVersion: 1,
      rules: [
        TriageRule(
          id: "urgent-bugs",
          when: [.priorityEquals(priority: .critical)],
          outcome: TriageRuleOutcome(verdict: .todo)
        )
      ],
      defaultOutcome: TriageRuleOutcome(verdict: .undecided)
    )
  }
}
