import AppKit
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard debugging OCR policy batch")
@MainActor
struct DashboardDebuggingOCRPolicyBatchTests {
  @Test("Clipboard privacy preprocessor skips access that would require confirmation")
  func clipboardPrivacyPreprocessorSkipsAccessThatWouldRequireConfirmation() {
    let center = AutomationPolicyCenter(
      fileURL: temporaryDirectory().appendingPathComponent("policies.json")
    )
    center.setPolicyEnabled("clipboard.image-ocr", isEnabled: true)

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
    let center = AutomationPolicyCenter(fileURL: directory.appendingPathComponent("policies.json"))
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
