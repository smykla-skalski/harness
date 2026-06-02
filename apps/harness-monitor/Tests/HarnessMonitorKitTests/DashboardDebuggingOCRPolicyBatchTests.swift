import AppKit
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard debugging OCR policy batch")
@MainActor
struct DashboardDebuggingOCRPolicyBatchTests {
  @Test("Clipboard privacy preprocessor skips access that would require confirmation")
  func clipboardPrivacyPreprocessorSkipsAccessThatWouldRequireConfirmation() {
    let center = AutomationPolicyCenter(eventDirectoryURL: temporaryDirectory())
    var policy = AutomationPolicyDocument.defaultPolicy(for: .clipboard)
    policy.isEnabled = true
    center.replacePolicy(policy)

    let decision = center.decision(
      for: .clipboard,
      contentKinds: [.image],
      accessBehaviorDescription: "ask"
    )

    #expect(!decision.isAllowed)
    #expect(decision.reason == "Pasteboard access requires confirmation")
  }

  @Test("OCR intake only deduplicates when the policy preprocessor is enabled")
  func ocrIntakeOnlyDeduplicatesWhenPolicyPreprocessorIsEnabled() {
    let image = syntheticImage()
    let candidates = [
      imageCandidate(image: image, sourceName: "Synthetic first.png"),
      imageCandidate(image: image, sourceName: "Synthetic second.png"),
    ]
    var policy = AutomationPolicyDocument.defaultPolicy(for: .manualOCRPaste)
    policy.preprocessors = []

    let unmerged = DashboardOCRIntakePolicyEvaluation.evaluate(
      source: .paste,
      decision: AutomationPolicyDecision(policy: policy, isAllowed: true, reason: nil),
      candidates: candidates
    )

    policy.preprocessors = [.dedupeByFingerprint]
    let merged = DashboardOCRIntakePolicyEvaluation.evaluate(
      source: .paste,
      decision: AutomationPolicyDecision(policy: policy, isAllowed: true, reason: nil),
      candidates: candidates
    )

    #expect(
      unmerged.candidates.map(\.sourceName) == [
        "Synthetic first.png",
        "Synthetic second.png",
      ]
    )
    #expect(merged.candidates.count == 1)
    #expect(merged.candidates.first?.sourceMetadata.map(\.name) == candidates.map(\.sourceName))
  }

  @Test("Background clipboard OCR persists recognized text and audits source application")
  func backgroundClipboardOCRPersistsRecognizedTextAndAuditsSourceApplication() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let center = AutomationPolicyCenter(eventDirectoryURL: directory)
    let recentStore = DashboardOCRRecentImageStore(
      directoryURL: directory.appendingPathComponent("recents", isDirectory: true),
      maxItems: 4
    )
    var policy = AutomationPolicyDocument.defaultPolicy(for: .clipboard)
    policy.isEnabled = true
    policy.actions = [.ocrImage, .rememberRecentScan, .recordMetadata]
    policy.postprocessors = [.sourceSpecificTextCleanup, .persistResult, .auditEvent]
    let sourceApplication = AutomationSourceApplication(
      bundleIdentifier: "com.example.synthetic-source",
      localizedName: "Synthetic Source",
      processIdentifier: 123
    )
    let dispatch = ClipboardAutomationDispatch(
      candidates: [
        imageCandidate(image: syntheticImage(), sourceName: "Synthetic clipboard.png")
      ],
      shouldOpenDashboardDebugging: false,
      policyDecision: AutomationPolicyDecision(policy: policy, isAllowed: true, reason: nil),
      sourceApplication: sourceApplication
    )

    await ClipboardAutomationBackgroundOCRProcessor.process(
      dispatch,
      center: center,
      recentStore: recentStore
    ) { _ in
      .success("Synthetic recognized text")
    }

    let recent = try #require(recentStore.load().first)
    let event = try #require(center.recentAutomationEvents.first)
    #expect(recent.recognizedText == "Synthetic recognized text")
    #expect(event.source == .clipboard)
    #expect(event.textPreview == "Synthetic recognized text")
    #expect(event.sourceApplication == sourceApplication)
    #expect(event.trigger == "Clipboard policy background recognition")
    #expect(center.clipboardRuntimeState == .matched("Clipboard Image OCR"))
  }

  @Test("Pending clipboard policy OCR keeps first matched policy when manual paste also queues")
  func pendingClipboardPolicyOCRKeepsFirstMatchedPolicyWhenManualPasteAlsoQueues() throws {
    DashboardDebuggingOCRPasteboardRequests.resetForTesting()
    defer { DashboardDebuggingOCRPasteboardRequests.resetForTesting() }
    let image = syntheticImage()
    let data = try #require(image.tiffRepresentation)
    var policy = AutomationPolicyDocument.defaultPolicy(for: .clipboard)
    policy.isEnabled = true
    let decision = AutomationPolicyDecision(policy: policy, isAllowed: true, reason: nil)

    let didQueuePolicy = DashboardDebuggingOCRPasteboardRequests.requestAutomationClipboard(
      candidates: [imageCandidate(image: image, sourceName: "Synthetic policy.png")],
      policyDecision: decision
    )
    let didQueueManual = DashboardDebuggingOCRPasteboardRequests.requestPaste(
      from: [
        DashboardOCRTransferImage(
          data: data,
          sourceName: "Synthetic manual.png",
          sourceDetail: nil
        )
      ]
    )
    let request = try #require(
      DashboardDebuggingOCRPasteboardRequests.takePendingRequest(after: 0)
    )

    #expect(didQueuePolicy)
    #expect(didQueueManual)
    #expect(request.source == .clipboardPolicy)
    #expect(request.policyDecision == decision)
    #expect(request.candidates.count == 1)
    #expect(
      request.candidates.first?.sourceMetadata.map(\.name) == [
        "Synthetic policy.png",
        "Synthetic manual.png",
      ]
    )
  }

  @Test("Denied manual OCR paste does not queue a Debug OCR request")
  func deniedManualOCRPasteDoesNotQueueDebugOCRRequest() {
    DashboardDebuggingOCRPasteboardRequests.resetForTesting()
    defer { DashboardDebuggingOCRPasteboardRequests.resetForTesting() }
    let decision = AutomationPolicyDecision(
      policy: AutomationPolicyDocument.defaultPolicy(for: .manualOCRPaste),
      isAllowed: false,
      reason: "No enabled manual paste policy"
    )

    let didQueue = DashboardDebuggingOCRPasteboardRequests.requestManualPaste(
      candidates: [imageCandidate(image: syntheticImage(), sourceName: "Denied manual.png")],
      policyDecision: decision
    )

    #expect(!didQueue)
    #expect(DashboardDebuggingOCRPasteboardRequests.takePendingRequest(after: 0) == nil)
  }

  @Test("Manual OCR paste without Open Debugging action does not queue a Debug OCR request")
  func manualOCRPasteWithoutOpenDebuggingDoesNotQueueDebugOCRRequest() {
    DashboardDebuggingOCRPasteboardRequests.resetForTesting()
    defer { DashboardDebuggingOCRPasteboardRequests.resetForTesting() }
    var policy = AutomationPolicyDocument.defaultPolicy(for: .manualOCRPaste)
    policy.isEnabled = true
    policy.actions = [.ocrImage, .recordMetadata]
    let decision = AutomationPolicyDecision(policy: policy, isAllowed: true, reason: nil)

    let didQueue = DashboardDebuggingOCRPasteboardRequests.requestManualPaste(
      candidates: [imageCandidate(image: syntheticImage(), sourceName: "Background manual.png")],
      policyDecision: decision
    )

    #expect(!didQueue)
    #expect(DashboardDebuggingOCRPasteboardRequests.takePendingRequest(after: 0) == nil)
  }

  @Test("Manual OCR paste with Open Debugging action queues the policy request")
  func manualOCRPasteWithOpenDebuggingQueuesPolicyRequest() throws {
    DashboardDebuggingOCRPasteboardRequests.resetForTesting()
    defer { DashboardDebuggingOCRPasteboardRequests.resetForTesting() }
    var policy = AutomationPolicyDocument.defaultPolicy(for: .manualOCRPaste)
    policy.isEnabled = true
    policy.actions = [.ocrImage, .openDashboardDebugging, .recordMetadata]
    let decision = AutomationPolicyDecision(policy: policy, isAllowed: true, reason: nil)

    let didQueue = DashboardDebuggingOCRPasteboardRequests.requestManualPaste(
      candidates: [imageCandidate(image: syntheticImage(), sourceName: "Allowed manual.png")],
      policyDecision: decision
    )
    let request = try #require(
      DashboardDebuggingOCRPasteboardRequests.takePendingRequest(after: 0)
    )

    #expect(didQueue)
    #expect(request.source == .paste)
    #expect(request.policyDecision == decision)
    #expect(request.candidates.count == 1)
  }

  @Test(
    "Reviews image paste falls back to dynamic Manual OCR policy when no Reviews screenshot policy is enabled"
  )
  func reviewsImagePasteFallsBackToDynamicManualOCRPolicy() throws {
    DashboardDebuggingOCRPasteboardRequests.resetForTesting()
    DashboardReviewsScreenshotPasteboardRequests.resetForTesting()
    defer {
      DashboardDebuggingOCRPasteboardRequests.resetForTesting()
      DashboardReviewsScreenshotPasteboardRequests.resetForTesting()
    }
    let center = AutomationPolicyCenter(eventDirectoryURL: temporaryDirectory())
    center.replaceCanvasPolicies([dynamicManualOCRPastePolicy()])

    let result = DashboardImagePastePolicyDispatcher.requestPaste(
      from: [try transferImage(name: "Manual policy screenshot.png")],
      reviewsRouteActive: true,
      policyCenter: center
    )
    let manualRequest = try #require(
      DashboardDebuggingOCRPasteboardRequests.takePendingRequest(after: 0)
    )

    #expect(result == .manualOCRPaste)
    #expect(manualRequest.policyDecision?.policy.eventSource == .manualOCRPaste)
    #expect(manualRequest.policyDecision?.policy.executionPlan != nil)
    #expect(DashboardReviewsScreenshotPasteboardRequests.takePendingRequest(after: 0) == nil)
  }

  @Test("Reviews image paste prefers dynamic Reviews screenshot policy when it is enabled")
  func reviewsImagePastePrefersDynamicReviewsScreenshotPolicy() throws {
    DashboardDebuggingOCRPasteboardRequests.resetForTesting()
    DashboardReviewsScreenshotPasteboardRequests.resetForTesting()
    defer {
      DashboardDebuggingOCRPasteboardRequests.resetForTesting()
      DashboardReviewsScreenshotPasteboardRequests.resetForTesting()
    }
    let center = AutomationPolicyCenter(eventDirectoryURL: temporaryDirectory())
    center.replaceCanvasPolicies([
      dynamicManualOCRPastePolicy(),
      dynamicReviewScreenshotPastePolicy(),
    ])

    let result = DashboardImagePastePolicyDispatcher.requestPaste(
      from: [try transferImage(name: "Review policy screenshot.png")],
      reviewsRouteActive: true,
      policyCenter: center
    )
    let reviewRequest = try #require(
      DashboardReviewsScreenshotPasteboardRequests.takePendingRequest(after: 0)
    )

    #expect(result == .reviewScreenshotPaste)
    #expect(reviewRequest.candidates.count == 1)
    #expect(DashboardDebuggingOCRPasteboardRequests.takePendingRequest(after: 0) == nil)
  }

  @Test("Reviews image paste without a dynamic image policy queues nothing")
  func reviewsImagePasteWithoutDynamicImagePolicyQueuesNothing() throws {
    DashboardDebuggingOCRPasteboardRequests.resetForTesting()
    DashboardReviewsScreenshotPasteboardRequests.resetForTesting()
    defer {
      DashboardDebuggingOCRPasteboardRequests.resetForTesting()
      DashboardReviewsScreenshotPasteboardRequests.resetForTesting()
    }
    let center = AutomationPolicyCenter(eventDirectoryURL: temporaryDirectory())

    let result = DashboardImagePastePolicyDispatcher.requestPaste(
      from: [try transferImage(name: "Denied screenshot.png")],
      reviewsRouteActive: true,
      policyCenter: center
    )

    #expect(result == .notHandled)
    #expect(DashboardDebuggingOCRPasteboardRequests.takePendingRequest(after: 0) == nil)
    #expect(DashboardReviewsScreenshotPasteboardRequests.takePendingRequest(after: 0) == nil)
  }

  @Test("Recent OCR image store clears persisted images and manifest")
  func recentOCRImageStoreClearsPersistedImagesAndManifest() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DashboardOCRRecentImageStore(directoryURL: directory, maxItems: 4)
    let item = DashboardOCRImageItem(
      candidate: imageCandidate(image: syntheticImage(), sourceName: "Synthetic recent.png")
    )

    _ = store.record([item])
    #expect(!store.load().isEmpty)

    let recents = store.clear()

    #expect(recents.isEmpty)
    #expect(store.load().isEmpty)
    let persistedImages =
      (try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
      )) ?? []
    #expect(!persistedImages.contains { $0.pathExtension == "png" })
  }

  private func imageCandidate(
    image: NSImage,
    sourceName: String
  ) -> DashboardOCRImageCandidate {
    DashboardOCRImageCandidate(
      image: image,
      sourceName: sourceName,
      sourceDetail: "/tmp/synthetic-ocr",
      fingerprint: DashboardOCRImageFingerprint.make(image: image)
    )
  }

  private func transferImage(name: String) throws -> DashboardOCRTransferImage {
    let image = syntheticImage()
    let data = try #require(image.tiffRepresentation)
    return DashboardOCRTransferImage(data: data, sourceName: name, sourceDetail: nil)
  }

  private func dynamicManualOCRPastePolicy() -> AutomationPolicy {
    AutomationPolicy(
      id: "canvas.manualOCRPaste.test-source",
      name: "Manual OCR Paste",
      eventSource: .manualOCRPaste,
      isEnabled: true,
      priority: 1,
      match: AutomationPolicyMatch(contentKinds: [.image]),
      preprocessors: [.dedupeByFingerprint],
      actions: [],
      postprocessors: [.sourceSpecificTextCleanup, .persistResult, .auditEvent],
      executionPlan: AutomationPolicyExecutionPlan(
        sourceNodeID: "automation:manual-ocr-paste:source",
        eventSource: .manualOCRPaste,
        steps: [
          AutomationPolicyExecutionStep(
            nodeID: "automation:manual-ocr-paste:source",
            inputPayload: .event,
            outputPayload: .image,
            actions: []
          ),
          AutomationPolicyExecutionStep(
            nodeID: "automation:manual-ocr-paste:ocr",
            inputPayload: .image,
            outputPayload: .text,
            actions: [.ocrImage]
          ),
          AutomationPolicyExecutionStep(
            nodeID: "automation:manual-ocr-paste:hub",
            inputPayload: .text,
            outputPayload: .text,
            actions: []
          ),
          AutomationPolicyExecutionStep(
            nodeID: "automation:manual-ocr-paste:debug",
            inputPayload: .text,
            outputPayload: .unknown,
            actions: [.openDashboardDebugging]
          ),
          AutomationPolicyExecutionStep(
            nodeID: "automation:manual-ocr-paste:persist",
            inputPayload: .text,
            outputPayload: .unknown,
            actions: [.rememberRecentScan, .showFeedback, .recordMetadata]
          ),
        ],
        fanOuts: [
          AutomationPolicyFanOut(
            hubNodeID: "automation:manual-ocr-paste:hub",
            payload: .text,
            branches: [
              AutomationPolicyFanOutBranch(
                outputPortID: "out_1",
                targetNodeID: "automation:manual-ocr-paste:debug",
                actions: [.openDashboardDebugging]
              ),
              AutomationPolicyFanOutBranch(
                outputPortID: "out_2",
                targetNodeID: "automation:manual-ocr-paste:persist",
                actions: [.rememberRecentScan, .showFeedback, .recordMetadata]
              ),
            ]
          )
        ]
      )
    )
  }

  private func dynamicReviewScreenshotPastePolicy() -> AutomationPolicy {
    AutomationPolicy(
      id: "canvas.reviewScreenshotPaste.test-source",
      name: "Review Screenshot Paste",
      eventSource: .reviewScreenshotPaste,
      isEnabled: true,
      priority: 1,
      match: AutomationPolicyMatch(contentKinds: [.image]),
      preprocessors: [.dedupeByFingerprint],
      actions: [],
      postprocessors: [.auditEvent],
      ocrConfiguration: AutomationPolicyOCRConfiguration(),
      reviewPullRequestExtraction: ReviewPullRequestExtractionConfiguration(),
      executionPlan: AutomationPolicyExecutionPlan(
        sourceNodeID: "automation:review-screenshot:source",
        eventSource: .reviewScreenshotPaste,
        steps: [
          AutomationPolicyExecutionStep(
            nodeID: "automation:review-screenshot:source",
            inputPayload: .event,
            outputPayload: .image,
            actions: []
          ),
          AutomationPolicyExecutionStep(
            nodeID: "automation:review-screenshot:ocr",
            inputPayload: .image,
            outputPayload: .text,
            actions: [.ocrImage]
          ),
          AutomationPolicyExecutionStep(
            nodeID: "automation:review-screenshot:resolve",
            inputPayload: .text,
            outputPayload: .pullRequests,
            actions: [.extractGitHubPullRequests, .resolveReviewPullRequests]
          ),
          AutomationPolicyExecutionStep(
            nodeID: "automation:review-screenshot:copy",
            inputPayload: .pullRequests,
            outputPayload: .unknown,
            actions: [.copyReviewPullRequestList]
          ),
        ]
      )
    )
  }

  private func syntheticImage() -> NSImage {
    let image = NSImage(size: NSSize(width: 16, height: 16))
    image.lockFocus()
    NSColor.systemBlue.setFill()
    NSRect(origin: .zero, size: image.size).fill()
    image.unlockFocus()
    return image
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "DashboardDebuggingOCRPolicyBatch-\(UUID().uuidString)",
        isDirectory: true
      )
  }
}
