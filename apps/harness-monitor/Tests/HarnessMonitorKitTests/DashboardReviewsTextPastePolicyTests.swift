import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard Reviews text paste policies")
@MainActor
struct DashboardReviewsTextPastePolicyTests {
  @Test("Parser extracts and dedupes GitHub PR links from noisy pasted text")
  func parserExtractsAndDedupesNoisyGitHubPRLinks() {
    let text = """
      Ania 10:42 AM
      <https://github.com/kong/kuma/pull/16703/files#diff-abc|PR>
      date: 2026-05-29
      https: //github. com/smykla-skalski/harness/pull/1234 /files#discussion_r99
      random url https://example.invalid/not-a-pr
      kong/kuma#16703
      """

    let references = GitHubPullRequestReferenceParser.references(in: text)

    #expect(
      references.map(\.displayText) == [
        "kong/kuma#16703",
        "smykla-skalski/harness#1234",
      ])
    #expect(references[0].canonicalURLString == "https://github.com/kong/kuma/pull/16703")
  }

  @Test("Default document enables manual review text paste policy")
  func defaultDocumentEnablesManualReviewTextPastePolicy() {
    let document = AutomationPolicyDocument()
    let policy = document.policy(for: .manualReviewTextPaste)

    #expect(policy.id == "reviews.text-paste")
    #expect(policy.isEnabled)
    #expect(policy.match.contentKinds == [.text, .url])
    #expect(policy.preprocessors == [.normalizeGitHubPullRequestLinks, .dedupePullRequests])
    #expect(policy.actions.contains(.extractGitHubPullRequests))
    #expect(policy.actions.contains(.previewReviewApprovals))
    #expect(policy.actions.contains(.promptReviewApprovals))
  }

  @Test("Policy execution exposes pasted review actions and audit references")
  func policyExecutionExposesPastedReviewActionsAndAuditReferences() throws {
    let policy = AutomationPolicyDocument.defaultPolicy(for: .manualReviewTextPaste)
    let references = GitHubPullRequestReferenceParser.references(
      in: "approve https://github.com/kong/kuma/pull/16703/files")
    let request = AutomationPolicyExecutionRequest(
      source: .manualReviewTextPaste,
      decision: AutomationPolicyDecision(policy: policy, isAllowed: true, reason: nil),
      summary: "1 GitHub pull request link from Slack",
      contentKinds: [.text, .url],
      declaredTypes: ["public.utf8-plain-text"],
      detectedContentType: "public.utf8-plain-text",
      sourceApplication: nil,
      trigger: "test",
      metadata: ClipboardAutomationMetadataPayload(
        textPreview: "https://github.com/kong/kuma/pull/16703/files",
        filePaths: []
      ),
      reviewPullRequestReferences: references
    )

    let result = AutomationPolicyExecutionPipeline.execute(request)
    let event = try #require(result.eventRecord)

    #expect(result.outcome == .matched)
    #expect(result.reviewPullRequestReferences.map(\.displayText) == ["kong/kuma#16703"])
    #expect(result.executedActions == policy.actions)
    #expect(event.reviewPullRequests == ["kong/kuma#16703"])
    #expect(event.textPreview == "https://github.com/kong/kuma/pull/16703/files")
  }

  @Test("Policy execution skips review actions when no PR links are present")
  func policyExecutionSkipsReviewActionsWhenNoPRLinksArePresent() {
    var policy = AutomationPolicyDocument.defaultPolicy(for: .manualReviewTextPaste)
    policy.actions = [.extractGitHubPullRequests, .approveReviewPullRequests]
    let request = AutomationPolicyExecutionRequest(
      source: .manualReviewTextPaste,
      decision: AutomationPolicyDecision(policy: policy, isAllowed: true, reason: nil),
      summary: "No links",
      contentKinds: [.text],
      declaredTypes: ["public.utf8-plain-text"],
      detectedContentType: "public.utf8-plain-text",
      sourceApplication: nil,
      trigger: "test",
      metadata: ClipboardAutomationMetadataPayload(textPreview: "hello", filePaths: [])
    )

    let result = AutomationPolicyExecutionPipeline.execute(request)

    #expect(result.outcome == .skipped)
    #expect(result.reason == "No GitHub pull request links found")
    #expect(result.skippedActions == [.extractGitHubPullRequests, .approveReviewPullRequests])
  }
}
