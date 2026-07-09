import AppKit
import Foundation
import HarnessMonitorKit
import HarnessMonitorPolicyModels
import Testing

@testable import HarnessMonitorUIPreviewable

extension DashboardReviewsTextPastePolicyTests {
  @Test("Policy binding config round trips through Swift graph JSON")
  func policyBindingConfigRoundTripsThroughSwiftGraphJSON() throws {
    var binding = PolicyGraphAutomationBinding(
      eventSource: AutomationPolicyEventSource.reviewScreenshotPaste.rawValue
    )
    binding.ocrConfiguration = PolicyGraphOCRConfiguration(
      recognitionLevel: "fast",
      automaticallyDetectsLanguage: false,
      usesLanguageCorrection: false
    )
    binding.reviewPullRequestExtraction = PolicyGraphReviewPullRequestExtraction(
      repositoryMode: "policyRepositories",
      policyRepositories: ["kong/kuma"],
      numberMemoryEnabled: false,
      resultScope: "failing",
      failureSignalMode: "visualScreenshot",
      outputFormat: "markdownLinks",
      autoCopy: false,
      showSheet: true
    )

    let data = try JSONEncoder().encode(binding)
    let decoded = try JSONDecoder().decode(
      PolicyGraphAutomationBinding.self,
      from: data
    )

    #expect(decoded.ocrConfiguration?.recognitionLevel == "fast")
    #expect(decoded.reviewPullRequestExtraction?.repositoryMode == "policyRepositories")
    #expect(decoded.reviewPullRequestExtraction?.policyRepositories == ["kong/kuma"])
    #expect(decoded.reviewPullRequestExtraction?.outputFormat == "markdownLinks")
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

  @Test("Policy execution carries dry run approval intent from the policy")
  func policyExecutionCarriesDryRunApprovalIntentFromPolicy() {
    var policy = AutomationPolicyDocument.defaultPolicy(for: .manualReviewTextPaste)
    policy.dryRun = true
    let references = GitHubPullRequestReferenceParser.references(
      in: "https://github.com/kong/kuma/pull/16703")
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
        textPreview: "https://github.com/kong/kuma/pull/16703",
        filePaths: []
      ),
      reviewPullRequestReferences: references
    )

    let result = AutomationPolicyExecutionPipeline.execute(request)

    #expect(result.outcome == .matched)
    #expect(result.shouldDryRunReviewApprovals)
  }

  @Test("Policy execution runs screenshot PR actions from OCR row candidates")
  func policyExecutionRunsScreenshotPRActionsFromOCRRowCandidates() {
    let policy = AutomationPolicyDocument.defaultPolicy(for: .reviewScreenshotPaste)
    let request = AutomationPolicyExecutionRequest(
      source: .reviewScreenshotPaste,
      decision: AutomationPolicyDecision(policy: policy, isAllowed: true, reason: nil),
      summary: "1 screenshot row",
      contentKinds: [.image],
      declaredTypes: ["public.image"],
      detectedContentType: "public.image",
      sourceApplication: nil,
      trigger: "test",
      metadata: ClipboardAutomationMetadataPayload(textPreview: "#9845", filePaths: []),
      imageCandidates: [
        DashboardOCRImageCandidate(
          image: NSImage(size: NSSize(width: 1, height: 1)),
          sourceName: "screenshot.png",
          sourceDetail: nil,
          fingerprint: "test-image"
        )
      ],
      reviewPullRequestCandidateCount: 1
    )

    let result = AutomationPolicyExecutionPipeline.execute(request)

    #expect(result.outcome == .matched)
    #expect(result.executedActions.contains(.ocrImage))
    #expect(result.executedActions.contains(.extractGitHubPullRequests))
    #expect(result.executedActions.contains(.resolveReviewPullRequests))
    #expect(result.executedActions.contains(.copyReviewPullRequestList))
  }

  @Test("Policy execution copies extracted screenshot URLs without review rows")
  func policyExecutionCopiesExtractedScreenshotURLsWithoutReviewRows() {
    var policy = AutomationPolicyDocument.defaultPolicy(for: .reviewScreenshotPaste)
    policy.actions = [.copyExtractedGitHubPullRequestURLs]
    let references = GitHubPullRequestReferenceParser.references(
      in: "https://github.com/kong/kuma/pull/16703/files")
    let request = AutomationPolicyExecutionRequest(
      source: .reviewScreenshotPaste,
      decision: AutomationPolicyDecision(policy: policy, isAllowed: true, reason: nil),
      summary: "1 extracted URL",
      contentKinds: [.image, .text, .url],
      declaredTypes: ["public.image"],
      detectedContentType: "public.image",
      sourceApplication: nil,
      trigger: "test",
      metadata: ClipboardAutomationMetadataPayload(
        textPreview: "https://github.com/kong/kuma/pull/16703/files",
        filePaths: []
      ),
      reviewPullRequestReferences: references,
      reviewPullRequestCandidateCount: 0
    )

    let result = AutomationPolicyExecutionPipeline.execute(request)

    #expect(result.outcome == .matched)
    #expect(result.executedActions == [.copyExtractedGitHubPullRequestURLs])
    #expect(result.reviewPullRequestReferences.map(\.displayText) == ["kong/kuma#16703"])
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

  @Test("Reviews text paste loads live canvas workspace before policy decision")
  func reviewsTextPasteLoadsLiveCanvasWorkspaceBeforePolicyDecision() async throws {
    let client = RecordingHarnessClient()
    let document = Self.pastedPRDryRunPolicyDocument()
    let workspace = PolicyCanvasWorkspace(
      schemaVersion: 1,
      activeCanvasId: "pasted-pr-canvas",
      canvases: [
        Self.policyCanvasSummary(
          canvasId: "pasted-pr-canvas",
          title: "Pasted PR approvals",
          document: document
        )
      ]
    )
    client.configurePolicyCanvasWorkspace(
      workspace: workspace,
      documentsByCanvasID: ["pasted-pr-canvas": document]
    )
    let store = await makeBootstrappedStore(client: client)
    let center = AutomationPolicyCenter()

    let coldDecision = center.decision(
      for: .manualReviewTextPaste,
      contentKinds: [.text, .url],
      allowsPasteboardPrompt: true
    )
    #expect(!coldDecision.isAllowed)

    await store.ensurePolicyCanvasWorkspaceLoadedForRuntimePolicies()
    DashboardAutomationPolicyRuntimeSynchronizer.synchronizeEnforcedCanvasAutomationPolicies(
      policyCenter: center,
      workspace: store.globalPolicyCanvasWorkspace,
      activeDocument: store.globalPolicyPipeline
    )
    let loadedDecision = center.decision(
      for: .manualReviewTextPaste,
      contentKinds: [.text, .url],
      allowsPasteboardPrompt: true
    )

    #expect(loadedDecision.isAllowed)
    #expect(loadedDecision.policy.name == "Review Text Paste")
    #expect(loadedDecision.policy.isDryRun)
    #expect(client.readCallCount(.policyCanvasWorkspace) == 1)
  }

  @Test("Runtime policy loader skips workspace refresh after policy canvas is loaded")
  func runtimePolicyLoaderSkipsWorkspaceRefreshAfterPolicyCanvasIsLoaded() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    await store.refreshPolicyPipeline()
    let baselineWorkspaceReads = client.readCallCount(.policyCanvasWorkspace)

    await store.ensurePolicyCanvasWorkspaceLoadedForRuntimePolicies()

    #expect(client.readCallCount(.policyCanvasWorkspace) == baselineWorkspaceReads)
  }
}

extension DashboardReviewsTextPastePolicyTests {
  fileprivate static func pastedPRDryRunPolicyDocument() -> PolicyPipelineDocument {
    PolicyPipelineDocument(
      revision: 1,
      mode: .enforced,
      nodes: [
        policyCanvasPipelineNode(
          id: "automation:review-text-paste:source",
          title: "Review Text Paste",
          kind: .actionStep(PolicyActionStep(actionId: "automation.review_text_paste")),
          automation: reviewTextPasteAutomationBinding(),
          inputs: [],
          outputs: ["default"]
        ),
        policyCanvasPipelineNode(
          id: "automation:review-text-paste:dry-run",
          title: "Dry-run gate",
          kind: .dryRunGate(reasonCode: .dryRunRequired),
          inputs: ["in"],
          outputs: []
        ),
      ],
      edges: [
        PolicyPipelineEdge(
          id: "edge:review-text-paste:dry-run",
          fromNodeId: "automation:review-text-paste:source",
          fromPort: "default",
          toNodeId: "automation:review-text-paste:dry-run",
          toPort: "in"
        )
      ],
      groups: []
    )
  }

  fileprivate static func policyCanvasSummary(
    canvasId: String,
    title: String,
    document: PolicyPipelineDocument
  ) -> PolicyCanvasSummary {
    PolicyCanvasSummary(
      canvasId: canvasId,
      title: title,
      revision: document.revision,
      mode: document.mode,
      document: document,
      nodeCount: document.nodes.count,
      edgeCount: document.edges.count,
      groupCount: document.groups.count,
      updatedAt: "2026-05-30T00:00:00Z"
    )
  }

  fileprivate static func policyCanvasPipelineNode(
    id: String,
    title: String,
    kind: PolicyGraphNodeKind,
    automation: PolicyGraphAutomationBinding? = nil,
    inputs: [String],
    outputs: [String]
  ) -> PolicyPipelineNode {
    PolicyPipelineNode(
      id: PolicyGraphNodeId(id),
      title: title,
      kind: kind,
      automation: automation,
      inputs: inputs.map { PolicyPipelinePort(id: PolicyGraphPortId($0), title: $0) },
      outputs: outputs.map { PolicyPipelinePort(id: PolicyGraphPortId($0), title: $0) }
    )
  }

  fileprivate static func reviewTextPasteAutomationBinding() -> PolicyGraphAutomationBinding {
    PolicyGraphAutomationBinding(
      isEnabled: true,
      eventSource: AutomationPolicyEventSource.manualReviewTextPaste.rawValue,
      contentKinds: [
        AutomationClipboardContentKind.text.rawValue,
        AutomationClipboardContentKind.url.rawValue,
      ],
      preprocessors: [
        AutomationPolicyPreprocessor.normalizeGitHubPullRequestLinks.rawValue,
        AutomationPolicyPreprocessor.dedupePullRequests.rawValue,
      ],
      actions: [
        AutomationPolicyAction.extractGitHubPullRequests.rawValue,
        AutomationPolicyAction.previewReviewApprovals.rawValue,
        AutomationPolicyAction.promptReviewApprovals.rawValue,
        AutomationPolicyAction.recordMetadata.rawValue,
      ],
      postprocessors: [AutomationPolicyPostprocessor.auditEvent.rawValue],
      sourceAppMode: AutomationSourceAppMode.allExceptDenied.rawValue
    )
  }
}
