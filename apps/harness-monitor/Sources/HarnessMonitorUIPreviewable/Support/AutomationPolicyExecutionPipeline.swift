import Foundation

struct AutomationPolicyExecutionRequest {
  let source: AutomationPolicyEventSource
  let decision: AutomationPolicyDecision
  let summary: String
  let contentKinds: Set<AutomationClipboardContentKind>
  let declaredTypes: [String]
  let detectedContentType: String?
  let sourceApplication: AutomationSourceApplication?
  let trigger: String
  let metadata: ClipboardAutomationMetadataPayload
  let imageCandidates: [DashboardOCRImageCandidate]
  let reviewPullRequestReferences: [GitHubPullRequestReference]
  let reviewPullRequestCandidateCount: Int

  init(
    source: AutomationPolicyEventSource,
    decision: AutomationPolicyDecision,
    summary: String,
    contentKinds: Set<AutomationClipboardContentKind>,
    declaredTypes: [String],
    detectedContentType: String?,
    sourceApplication: AutomationSourceApplication?,
    trigger: String,
    metadata: ClipboardAutomationMetadataPayload,
    imageCandidates: [DashboardOCRImageCandidate] = [],
    reviewPullRequestReferences: [GitHubPullRequestReference] = [],
    reviewPullRequestCandidateCount: Int? = nil
  ) {
    self.source = source
    self.decision = decision
    self.summary = summary
    self.contentKinds = contentKinds
    self.declaredTypes = declaredTypes
    self.detectedContentType = detectedContentType
    self.sourceApplication = sourceApplication
    self.trigger = trigger
    self.metadata = metadata
    self.imageCandidates = imageCandidates
    self.reviewPullRequestReferences = reviewPullRequestReferences
    self.reviewPullRequestCandidateCount =
      reviewPullRequestCandidateCount ?? reviewPullRequestReferences.count
  }
}

struct AutomationPolicyExecutionResult {
  let policyDecision: AutomationPolicyDecision
  let policyName: String
  let outcome: AutomationPolicyEventOutcome
  let reason: String?
  let sourceApplication: AutomationSourceApplication?
  let executedActions: [AutomationPolicyAction]
  let skippedActions: [AutomationPolicyAction]
  let executedPostprocessors: [AutomationPolicyPostprocessor]
  let eventRecord: AutomationPolicyEventRecord?
  let imageCandidates: [DashboardOCRImageCandidate]
  let reviewPullRequestReferences: [GitHubPullRequestReference]
  let shouldOpenDashboardDebugging: Bool

  var shouldDryRunReviewApprovals: Bool {
    policyDecision.policy.isDryRun && !reviewPullRequestReferences.isEmpty
  }

  var runtimeState: ClipboardAutomationRuntimeState {
    switch outcome {
    case .matched:
      .matched(policyName)
    case .denied:
      .denied
    case .failed:
      .failed(reason ?? "Policy execution failed")
    case .skipped:
      .skipped(reason ?? "No policy action ran")
    }
  }

  var dispatch: ClipboardAutomationDispatch? {
    guard shouldOpenDashboardDebugging || !imageCandidates.isEmpty else {
      return nil
    }
    return ClipboardAutomationDispatch(
      candidates: imageCandidates,
      shouldOpenDashboardDebugging: shouldOpenDashboardDebugging,
      policyDecision: policyDecision,
      sourceApplication: sourceApplication
    )
  }
}

enum AutomationPolicyExecutionPipeline {
  static func execute(_ request: AutomationPolicyExecutionRequest)
    -> AutomationPolicyExecutionResult
  {
    guard request.decision.isAllowed else {
      var execution = AutomationPolicyActionExecution()
      execution.skippedActions = executionActions(for: request.decision.policy)
      return result(
        request,
        outcome: deniedOutcome(for: request.decision),
        reason: request.decision.reason,
        execution: execution
      )
    }

    let execution = actionExecution(for: request)
    let outcome: AutomationPolicyEventOutcome =
      execution.executedActions.isEmpty ? .skipped : .matched
    let reason = execution.executedActions.isEmpty ? execution.reason : nil
    return result(
      request,
      outcome: outcome,
      reason: reason,
      execution: execution
    )
  }

  private static func actionExecution(
    for request: AutomationPolicyExecutionRequest
  ) -> AutomationPolicyActionExecution {
    var execution = AutomationPolicyActionExecution()
    for action in executionActions(for: request.decision.policy) {
      switch action {
      case .ocrImage:
        execution.handleOCRAction(request)
      case .extractGitHubPullRequests:
        execution.handleReviewExtractionAction(request)
      case .resolveReviewPullRequests, .copyReviewPullRequestList, .previewReviewApprovals,
        .promptReviewApprovals, .approveReviewPullRequests, .runReviewPolicy:
        execution.handleReviewAction(action, request: request)
      case .recordMetadata:
        execution.executedActions.append(action)
      case .openDashboardDebugging:
        execution.executedActions.append(action)
      case .rememberRecentScan, .showFeedback:
        execution.handleOCRFollowUpAction(action, request: request)
      }
    }
    if execution.reason == nil, execution.executedActions.isEmpty {
      execution.reason = "No executable actions for matched policy"
    }
    return execution
  }

  private static func result(
    _ request: AutomationPolicyExecutionRequest,
    outcome: AutomationPolicyEventOutcome,
    reason: String?,
    execution: AutomationPolicyActionExecution
  ) -> AutomationPolicyExecutionResult {
    let executedPostprocessors: [AutomationPolicyPostprocessor] =
      request.decision.shouldAuditEvent ? [.auditEvent] : []
    let eventRecord =
      request.decision.shouldAuditEvent
      ? eventRecord(
        request,
        outcome: outcome,
        reason: reason,
        execution: execution,
        executedPostprocessors: executedPostprocessors
      )
      : nil
    return AutomationPolicyExecutionResult(
      policyDecision: request.decision,
      policyName: request.decision.policy.name,
      outcome: outcome,
      reason: reason,
      sourceApplication: request.sourceApplication,
      executedActions: execution.executedActions,
      skippedActions: execution.skippedActions,
      executedPostprocessors: executedPostprocessors,
      eventRecord: eventRecord,
      imageCandidates: execution.imageCandidates,
      reviewPullRequestReferences: execution.reviewPullRequestReferences,
      shouldOpenDashboardDebugging: execution.executedActions.contains(.openDashboardDebugging)
    )
  }

  private static func eventRecord(
    _ request: AutomationPolicyExecutionRequest,
    outcome: AutomationPolicyEventOutcome,
    reason: String?,
    execution: AutomationPolicyActionExecution,
    executedPostprocessors: [AutomationPolicyPostprocessor]
  ) -> AutomationPolicyEventRecord {
    AutomationPolicyEventRecord(
      source: request.source,
      outcome: outcome,
      policyID: request.decision.policy.id,
      policyName: request.decision.policy.name,
      reason: reason,
      summary: request.summary,
      contentKinds: request.contentKinds,
      declaredTypes: request.declaredTypes,
      detectedContentType: request.detectedContentType,
      sourceApplication: request.sourceApplication,
      actions: executionActions(for: request.decision.policy),
      postprocessors: request.decision.policy.postprocessors,
      executedActions: execution.executedActions,
      skippedActions: execution.skippedActions,
      executedPostprocessors: executedPostprocessors,
      trigger: request.trigger,
      textPreview: request.metadata.textPreview,
      filePaths: request.metadata.filePaths,
      reviewPullRequests: request.reviewPullRequestReferences.map(\.displayText)
    )
  }

  private static func deniedOutcome(
    for decision: AutomationPolicyDecision
  ) -> AutomationPolicyEventOutcome {
    let reason = decision.reason?.lowercased() ?? ""
    return reason.contains("denied") ? .denied : .skipped
  }

  private static func executionActions(for policy: AutomationPolicy) -> [AutomationPolicyAction] {
    guard let plan = policy.executionPlan, !plan.fanOuts.isEmpty else {
      return policy.executionActions
    }
    let branchTargetIDs = Set(
      plan.fanOuts.flatMap { fanOut in
        fanOut.branches.map(\.targetNodeID)
      }
    )
    var actions: [AutomationPolicyAction] = []
    for step in plan.steps where !branchTargetIDs.contains(step.nodeID) {
      append(step.actions, to: &actions)
    }
    for fanOut in plan.fanOuts {
      for branch in fanOut.branches {
        append(branch.actions, to: &actions)
      }
    }
    return actions
  }

  private static func append(
    _ candidates: [AutomationPolicyAction],
    to actions: inout [AutomationPolicyAction]
  ) {
    for action in candidates where !actions.contains(action) {
      actions.append(action)
    }
  }
}

private struct AutomationPolicyActionExecution {
  var executedActions: [AutomationPolicyAction] = []
  var skippedActions: [AutomationPolicyAction] = []
  var imageCandidates: [DashboardOCRImageCandidate] = []
  var reviewPullRequestReferences: [GitHubPullRequestReference] = []
  var reason: String?

  mutating func handleOCRAction(_ request: AutomationPolicyExecutionRequest) {
    guard request.contentKinds.contains(.image) else {
      skippedActions.append(.ocrImage)
      reason = "Matched content is not an image"
      return
    }
    guard !request.imageCandidates.isEmpty else {
      skippedActions.append(.ocrImage)
      reason = "No readable images found"
      return
    }
    executedActions.append(.ocrImage)
    imageCandidates = request.imageCandidates
  }

  mutating func handleReviewExtractionAction(_ request: AutomationPolicyExecutionRequest) {
    guard
      request.contentKinds.contains(.text) || request.contentKinds.contains(.url)
        || request.contentKinds.contains(.image)
    else {
      skippedActions.append(.extractGitHubPullRequests)
      reason = "Matched content is not text"
      return
    }
    guard request.reviewPullRequestCandidateCount > 0 else {
      skippedActions.append(.extractGitHubPullRequests)
      reason = "No GitHub pull request links found"
      return
    }
    executedActions.append(.extractGitHubPullRequests)
    reviewPullRequestReferences = request.reviewPullRequestReferences
  }

  mutating func handleReviewAction(
    _ action: AutomationPolicyAction,
    request: AutomationPolicyExecutionRequest
  ) {
    guard request.reviewPullRequestCandidateCount > 0 else {
      skippedActions.append(action)
      if reason == nil {
        reason = "No GitHub pull request links found"
      }
      return
    }
    executedActions.append(action)
    reviewPullRequestReferences = request.reviewPullRequestReferences
  }

  mutating func handleOCRFollowUpAction(
    _ action: AutomationPolicyAction,
    request: AutomationPolicyExecutionRequest
  ) {
    guard request.contentKinds.contains(.image), !request.imageCandidates.isEmpty else {
      skippedActions.append(action)
      return
    }
    executedActions.append(action)
  }
}
