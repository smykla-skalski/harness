import Foundation

extension HarnessMonitorStore {
  @discardableResult
  public func submitTaskForReview(
    taskID: String,
    summary: String? = nil,
    suggestedPersona: String? = nil,
    actor: String = "harness-app"
  ) async -> Bool {
    let actionName = "Submit for review"
    guard let action = prepareSelectedSessionAction(named: actionName) else { return false }
    let actor = controlPlaneActionActor(for: actor)
    return await mutateSelectedSession(
      actionName: actionName,
      actionID: InspectorActionID.submitTaskForReview(
        sessionID: action.sessionID,
        taskID: taskID
      ).key,
      using: action.client,
      sessionID: action.sessionID,
      mutation: {
        try await action.client.submitTaskForReview(
          sessionID: action.sessionID,
          taskID: taskID,
          request: TaskSubmitForReviewRequest(
            actor: actor,
            summary: summary,
            suggestedPersona: suggestedPersona
          )
        )
      }
    )
  }

  @discardableResult
  public func claimTaskReview(
    taskID: String,
    actor: String = "harness-app"
  ) async -> Bool {
    let actionName = "Claim review"
    guard let action = prepareSelectedSessionAction(named: actionName) else { return false }
    let actor = controlPlaneActionActor(for: actor)
    return await mutateSelectedSession(
      actionName: actionName,
      actionID: InspectorActionID.claimTaskReview(
        sessionID: action.sessionID,
        taskID: taskID
      ).key,
      using: action.client,
      sessionID: action.sessionID,
      mutation: {
        try await action.client.claimTaskReview(
          sessionID: action.sessionID,
          taskID: taskID,
          request: TaskClaimReviewRequest(actor: actor)
        )
      }
    )
  }

  @discardableResult
  public func submitTaskReview(
    taskID: String,
    verdict: ReviewVerdict,
    summary: String,
    points: [ReviewPoint] = [],
    actor: String = "harness-app"
  ) async -> Bool {
    let actionName = "Submit review"
    guard let action = prepareSelectedSessionAction(named: actionName) else { return false }
    let actor = controlPlaneActionActor(for: actor)
    return await mutateSelectedSession(
      actionName: actionName,
      actionID: InspectorActionID.submitTaskReview(
        sessionID: action.sessionID,
        taskID: taskID
      ).key,
      using: action.client,
      sessionID: action.sessionID,
      mutation: {
        try await action.client.submitTaskReview(
          sessionID: action.sessionID,
          taskID: taskID,
          request: TaskSubmitReviewRequest(
            actor: actor,
            verdict: verdict,
            summary: summary,
            points: points
          )
        )
      }
    )
  }

  @discardableResult
  public func respondTaskReview(
    taskID: String,
    agreed: [String] = [],
    disputed: [String] = [],
    note: String? = nil,
    actor: String = "harness-app"
  ) async -> Bool {
    let actionName = "Respond to review"
    guard let action = prepareSelectedSessionAction(named: actionName) else { return false }
    let actor = controlPlaneActionActor(for: actor)
    return await mutateSelectedSession(
      actionName: actionName,
      actionID: InspectorActionID.respondTaskReview(
        sessionID: action.sessionID,
        taskID: taskID
      ).key,
      using: action.client,
      sessionID: action.sessionID,
      mutation: {
        try await action.client.respondTaskReview(
          sessionID: action.sessionID,
          taskID: taskID,
          request: TaskRespondReviewRequest(
            actor: actor,
            agreed: agreed,
            disputed: disputed,
            note: note
          )
        )
      }
    )
  }

  @discardableResult
  public func arbitrateTask(
    taskID: String,
    verdict: ReviewVerdict,
    summary: String,
    actor: String = "harness-app"
  ) async -> Bool {
    let actionName = "Arbitrate task"
    guard let action = prepareSelectedSessionAction(named: actionName) else { return false }
    let actor = controlPlaneActionActor(for: actor)
    return await mutateSelectedSession(
      actionName: actionName,
      actionID: InspectorActionID.arbitrateTask(
        sessionID: action.sessionID,
        taskID: taskID
      ).key,
      using: action.client,
      sessionID: action.sessionID,
      mutation: {
        try await action.client.arbitrateTask(
          sessionID: action.sessionID,
          taskID: taskID,
          request: TaskArbitrateRequest(
            actor: actor,
            verdict: verdict,
            summary: summary
          )
        )
      }
    )
  }

  @discardableResult
  public func applyImproverPatch(
    issueId: String,
    target: ImproverTarget,
    relPath: String,
    newContents: String,
    projectDir: String,
    dryRun: Bool = false,
    actor: String = "harness-app"
  ) async -> Bool {
    let actionName = "Apply improver patch"
    guard let action = prepareSelectedSessionAction(named: actionName) else { return false }
    let actor = controlPlaneActionActor(for: actor)
    return await mutateSelectedSession(
      actionName: actionName,
      actionID: InspectorActionID.applyImproverPatch(
        sessionID: action.sessionID,
        issueID: issueId
      ).key,
      using: action.client,
      sessionID: action.sessionID,
      mutation: {
        try await action.client.applyImproverPatch(
          sessionID: action.sessionID,
          request: ImproverApplyRequest(
            actor: actor,
            issueId: issueId,
            target: target,
            relPath: relPath,
            newContents: newContents,
            projectDir: projectDir,
            dryRun: dryRun
          )
        )
      }
    )
  }
}
