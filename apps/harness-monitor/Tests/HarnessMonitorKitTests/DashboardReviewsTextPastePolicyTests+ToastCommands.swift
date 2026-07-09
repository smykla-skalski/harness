import Foundation
import HarnessMonitorKit
import Testing

@testable import HarnessMonitorUIPreviewable

extension DashboardReviewsTextPastePolicyTests {
  @Test("Policy execution exposes activity toast commands from the execution plan")
  func policyExecutionExposesActivityToastCommandsFromExecutionPlan() {
    let toastCommands = [
      AutomationPolicyToastCommand(
        kind: .show,
        message: "Processing PR URLs",
        position: .bottomTrailing
      ),
      AutomationPolicyToastCommand(
        kind: .update,
        message: "Loading PR details"
      ),
      AutomationPolicyToastCommand(kind: .hide),
    ]
    let executionPlan = AutomationPolicyExecutionPlan(
      sourceNodeID: "review-text-paste",
      eventSource: .manualReviewTextPaste,
      steps: [
        AutomationPolicyExecutionStep(
          nodeID: "review-text-paste",
          inputPayload: .event,
          outputPayload: .text,
          actions: [.extractGitHubPullRequests]
        ),
        AutomationPolicyExecutionStep(
          nodeID: "show-progress",
          inputPayload: .text,
          outputPayload: .text,
          actions: [.showActivityToast],
          toastCommand: toastCommands[0]
        ),
        AutomationPolicyExecutionStep(
          nodeID: "update-progress",
          inputPayload: .text,
          outputPayload: .pullRequests,
          actions: [.updateActivityToast, .approveReviewPullRequests],
          toastCommand: toastCommands[1]
        ),
        AutomationPolicyExecutionStep(
          nodeID: "hide-progress",
          inputPayload: .pullRequests,
          outputPayload: .pullRequests,
          actions: [.hideActivityToast],
          toastCommand: toastCommands[2]
        ),
      ]
    )
    let policy = AutomationPolicy(
      id: "policy.manual-review-text-paste.activity",
      name: "Review Text Paste",
      eventSource: .manualReviewTextPaste,
      isEnabled: true,
      priority: 1,
      match: AutomationPolicyMatch(contentKinds: [.text, .url]),
      preprocessors: [],
      actions: executionPlan.orderedActions,
      postprocessors: [.auditEvent],
      executionPlan: executionPlan
    )
    let references = GitHubPullRequestReferenceParser.references(
      in: "https://github.com/example/repo/pull/42"
    )
    let request = AutomationPolicyExecutionRequest(
      source: .manualReviewTextPaste,
      decision: AutomationPolicyDecision(policy: policy, isAllowed: true, reason: nil),
      summary: "1 GitHub pull request link from browser",
      contentKinds: [.text, .url],
      declaredTypes: ["public.utf8-plain-text"],
      detectedContentType: "public.utf8-plain-text",
      sourceApplication: nil,
      trigger: "test",
      metadata: ClipboardAutomationMetadataPayload(
        textPreview: "https://github.com/example/repo/pull/42",
        filePaths: []
      ),
      reviewPullRequestReferences: references
    )

    let result = AutomationPolicyExecutionPipeline.execute(request)

    #expect(result.outcome == .matched)
    #expect(result.executedActions.contains(.showActivityToast))
    #expect(result.executedActions.contains(.updateActivityToast))
    #expect(result.executedActions.contains(.hideActivityToast))
    #expect(result.executedActions.contains(.approveReviewPullRequests))
    #expect(result.toastCommands == toastCommands)
  }
}
