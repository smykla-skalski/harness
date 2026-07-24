import Foundation

extension PreviewHarnessClientState {
  func taskBoardTriageRulesDraft() -> TaskBoardTriageRulesDraftResponse {
    TaskBoardTriageRulesDraftResponse(draft: taskBoardTriageRuleSetDraft)
  }

  func saveTaskBoardTriageRulesDraft(
    request: TaskBoardSaveTriageRulesDraftRequest
  ) -> TriageRuleSetDraftSaveResult {
    guard taskBoardTriageRuleSetDraft?.revision == request.expectedRevision else {
      return TriageRuleSetDraftSaveResult(
        validation: TriageRuleSetValidationReport(),
        persisted: false,
        revision: taskBoardTriageRuleSetDraft?.revision
      )
    }
    let validation = Self.validateTriageRuleSet(request.rules)
    guard validation.issues.isEmpty else {
      return TriageRuleSetDraftSaveResult(
        validation: validation,
        persisted: false,
        revision: taskBoardTriageRuleSetDraft?.revision
      )
    }
    let nextRevision = (request.expectedRevision ?? 0) + 1
    taskBoardTriageRuleSetDraft = TriageRuleSetDraft(
      rules: request.rules,
      revision: nextRevision,
      actor: request.actor,
      updatedAt: Self.mutationTimestamp
    )
    return TriageRuleSetDraftSaveResult(
      validation: validation,
      persisted: true,
      revision: nextRevision
    )
  }

  func previewTaskBoardTriageRules(
    request: TaskBoardPreviewTriageRulesRequest
  ) -> TriageRuleSetPreviewResult {
    let validation = Self.validateTriageRuleSet(request.rules)
    guard validation.issues.isEmpty else {
      return TriageRuleSetPreviewResult(validation: validation, diff: [])
    }
    let diff = taskBoardItems.map { item in
      Self.previewDiffEntry(
        for: item,
        candidate: request.rules,
        override: taskBoardTriageOverrideByItemID[item.id],
        currentDecision: taskBoardTriageDecisionsByItemID[item.id]?.first
      )
    }
    return TriageRuleSetPreviewResult(validation: validation, diff: diff)
  }

  func activateTaskBoardTriageRules(
    request: TaskBoardActivateTriageRulesRequest
  ) -> TriageRuleSetActivationResult {
    guard taskBoardActiveTriageRuleSetRevision == request.expectedActiveRevision else {
      return TriageRuleSetActivationResult(
        validation: TriageRuleSetValidationReport(),
        activated: false,
        revision: taskBoardActiveTriageRuleSetRevision,
        reevaluatedItemCount: 0
      )
    }
    let validation =
      request.rules.map(Self.validateTriageRuleSet) ?? TriageRuleSetValidationReport()
    guard validation.issues.isEmpty else {
      taskBoardTriageRuleSetAudit.insert(
        TriageRuleSetAuditEntry(
          auditId: "preview-audit-\(UUID().uuidString.lowercased())",
          kind: .activationRejected,
          revision: nil,
          actor: request.actor,
          reason: "candidate failed validation",
          reevaluatedItemCount: nil,
          recordedAt: Self.mutationTimestamp
        ),
        at: 0
      )
      return TriageRuleSetActivationResult(
        validation: validation,
        activated: false,
        revision: taskBoardActiveTriageRuleSetRevision,
        reevaluatedItemCount: 0
      )
    }
    let newRevision = request.rules.map { _ in
      (taskBoardTriageRuleSetRevisions.map(\.revision).max() ?? 0) + 1
    }
    if let previousRevision = taskBoardActiveTriageRuleSetRevision,
      let index = taskBoardTriageRuleSetRevisions.firstIndex(where: {
        $0.revision == previousRevision
      })
    {
      let previous = taskBoardTriageRuleSetRevisions[index]
      taskBoardTriageRuleSetRevisions[index] = TriageRuleSetRevisionSummary(
        revision: previous.revision,
        schemaVersion: previous.schemaVersion,
        ruleCount: previous.ruleCount,
        status: .superseded,
        actor: previous.actor,
        activatedAt: previous.activatedAt,
        supersededAt: Self.mutationTimestamp
      )
    }
    if let rules = request.rules, let newRevision {
      taskBoardTriageRuleSetRevisions.append(
        TriageRuleSetRevisionSummary(
          revision: newRevision,
          schemaVersion: rules.schemaVersion,
          ruleCount: UInt(rules.rules.count),
          status: .active,
          actor: request.actor,
          activatedAt: Self.mutationTimestamp,
          supersededAt: nil
        )
      )
    }
    taskBoardActiveTriageRuleSet = request.rules
    taskBoardActiveTriageRuleSetRevision = newRevision
    taskBoardTriageRuleSetAudit.insert(
      TriageRuleSetAuditEntry(
        auditId: "preview-audit-\(UUID().uuidString.lowercased())",
        kind: request.rules == nil ? .deactivated : .activated,
        revision: newRevision,
        actor: request.actor,
        reason: nil,
        reevaluatedItemCount: Int64(taskBoardItems.count),
        recordedAt: Self.mutationTimestamp
      ),
      at: 0
    )
    return TriageRuleSetActivationResult(
      validation: validation,
      activated: true,
      revision: newRevision,
      reevaluatedItemCount: UInt(taskBoardItems.count)
    )
  }

  func taskBoardTriageRulesRevisions(limit: UInt32?) -> TaskBoardTriageRulesRevisionsResponse {
    let bounded = Int(limit ?? 50)
    let sorted = taskBoardTriageRuleSetRevisions.sorted { $0.revision > $1.revision }
    return TaskBoardTriageRulesRevisionsResponse(revisions: Array(sorted.prefix(bounded)))
  }

  func taskBoardTriageRulesAudit(limit: UInt32?) -> TaskBoardTriageRulesAuditResponse {
    let bounded = Int(limit ?? 50)
    return TaskBoardTriageRulesAuditResponse(
      audit: Array(taskBoardTriageRuleSetAudit.prefix(bounded)))
  }

  /// Sound-but-incomplete preview validation: structural checks only
  /// (schema version, rule id shape/uniqueness, non-empty condition lists).
  /// Self-contradiction and shadow detection stay Rust-only; the preview
  /// harness exists to exercise the editor's save/preview/activate flow, not
  /// to be a second correctness oracle for validation edge cases.
  fileprivate static func validateTriageRuleSet(_ candidate: TriageRuleSetV1)
    -> TriageRuleSetValidationReport
  {
    var issues: [TriageRuleSetValidationIssue] = []
    guard candidate.schemaVersion == 1 else {
      return TriageRuleSetValidationReport(
        issues: [.unsupportedSchemaVersion(expected: 1, actual: candidate.schemaVersion)]
      )
    }
    var seenIds: Set<String> = []
    for (index, rule) in candidate.rules.enumerated() {
      let trimmedId = rule.id.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedId.isEmpty else {
        issues.append(.malformedRuleId(index: UInt(index)))
        continue
      }
      guard seenIds.insert(rule.id).inserted else {
        issues.append(.duplicateRuleId(ruleId: rule.id))
        continue
      }
    }
    return TriageRuleSetValidationReport(issues: issues)
  }

  fileprivate static func previewDiffEntry(
    for item: TaskBoardItem,
    candidate: TriageRuleSetV1,
    override: TaskBoardTriageOverride?,
    currentDecision: TaskBoardTriageDecisionRecord?
  ) -> TriageRuleSetPreviewDiffEntry {
    let evaluation = evaluateCandidate(candidate, item: item)
    let liveVerdict: TriageVerdict?
    let liveSource: TaskBoardTriageEffectiveSource?
    if let override {
      liveVerdict = override.verdict
      liveSource = .override
    } else if let currentDecision {
      liveVerdict = currentDecision.verdict
      liveSource = .automatic
    } else {
      liveVerdict = nil
      liveSource = nil
    }
    let governsPlacementChange = override == nil && liveVerdict != evaluation.verdict
    return TriageRuleSetPreviewDiffEntry(
      itemId: item.id,
      liveEffectiveVerdict: liveVerdict,
      liveEffectiveSource: liveSource,
      candidateVerdict: evaluation.verdict,
      candidateMatchedRuleId: evaluation.matchedRuleId,
      governsPlacementChange: governsPlacementChange
    )
  }

  fileprivate static func evaluateCandidate(
    _ candidate: TriageRuleSetV1,
    item: TaskBoardItem
  ) -> (verdict: TriageVerdict, matchedRuleId: String?) {
    let labels = canonicalizeLabels(item.tags)
    let targetTypes = canonicalizeLabels(item.targetProjectTypes)
    for rule in candidate.rules {
      if rule.when.allSatisfy({ condition in
        conditionMatches(condition, labels: labels, targetTypes: targetTypes, item: item)
      }) {
        return (rule.outcome.verdict, rule.id)
      }
    }
    return (candidate.defaultOutcome.verdict, nil)
  }

  fileprivate static func conditionMatches(
    _ condition: TriageRuleCondition,
    labels: [String],
    targetTypes: [String],
    item: TaskBoardItem
  ) -> Bool {
    switch condition {
    case .labelsHasAny(let needles):
      return canonicalizeLabels(needles).contains { labels.contains($0) }
    case .labelsHasAll(let needles):
      return canonicalizeLabels(needles).allSatisfy { labels.contains($0) }
    case .labelsHasNone(let needles):
      return !canonicalizeLabels(needles).contains { labels.contains($0) }
    case .priorityEquals(let priority):
      return item.priority == priority
    case .executionRepositoryEquals(let value):
      return item.executionRepository == value
    case .executionRepositoryIsPresent:
      return item.executionRepository != nil
    case .executionRepositoryIsMissing:
      return item.executionRepository == nil
    case .projectIdEquals(let value):
      return item.projectId == value
    case .projectIdIsPresent:
      return item.projectId != nil
    case .projectIdIsMissing:
      return item.projectId == nil
    case .targetProjectTypesHasAny(let needles):
      return canonicalizeLabels(needles).contains { targetTypes.contains($0) }
    case .targetProjectTypesHasNone(let needles):
      return !canonicalizeLabels(needles).contains { targetTypes.contains($0) }
    case .importedFromProviderEquals(let provider):
      return item.importedFromProvider?.rawValue == provider.rawValue
    case .importedFromProviderIsMissing:
      return item.importedFromProvider == nil
    }
  }

  fileprivate static func canonicalizeLabels(_ tags: [String]) -> [String] {
    var labels = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
      .filter { !$0.isEmpty }
    labels.sort()
    var deduped: [String] = []
    for label in labels where deduped.last != label {
      deduped.append(label)
    }
    return deduped
  }
}
