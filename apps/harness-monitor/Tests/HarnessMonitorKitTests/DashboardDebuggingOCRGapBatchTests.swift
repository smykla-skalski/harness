import AppKit
import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard debugging OCR gap batch")
@MainActor
struct DashboardDebuggingOCRGapBatchTests {
  @Test("Automatic pasteboard privacy skips prompts but manual capture may prompt")
  func automaticPasteboardPrivacySkipsPromptsButManualCaptureMayPrompt() {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let center = AutomationPolicyCenter(fileURL: directory.appendingPathComponent("policies.json"))
    center.setPolicyEnabled("clipboard.image-ocr", isEnabled: true)

    let automaticDecision = center.decision(
      for: .clipboard,
      contentKinds: [.image],
      accessBehaviorDescription: "ask"
    )
    let manualDecision = center.decision(
      for: .clipboard,
      contentKinds: [.image],
      accessBehaviorDescription: "ask",
      allowsPasteboardPrompt: true
    )

    #expect(!automaticDecision.isAllowed)
    #expect(automaticDecision.reason == "Pasteboard access requires confirmation")
    #expect(manualDecision.isAllowed)
  }

  @Test("Clipboard snapshot keeps plain text out of file matches")
  func clipboardSnapshotKeepsPlainTextOutOfFileMatches() async {
    let pasteboard = NSPasteboard.withUniqueName()
    pasteboard.clearContents()
    pasteboard.setString("Synthetic clipboard text", forType: .string)

    let snapshot = await ClipboardAutomationSnapshot.make(
      from: pasteboard,
      reason: .manualCapture,
      observedSourceApplication: syntheticSourceApplication()
    )

    #expect(snapshot.contentKinds.contains(.text))
    #expect(!snapshot.contentKinds.contains(.file))
    #expect(snapshot.sourceApplication == syntheticSourceApplication())
  }

  @Test("Recent image store merges duplicate source metadata and keeps recognized text")
  func recentImageStoreMergesDuplicateSourceMetadataAndKeepsRecognizedText() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DashboardOCRRecentImageStore(directoryURL: directory, maxItems: 4)
    var firstItem = DashboardOCRImageItem(
      candidate: imageCandidate(
        sourceName: "Synthetic clipboard.png",
        sourceDetail: "/tmp/synthetic-clipboard",
        fingerprint: "duplicate-image"
      )
    )
    firstItem.recognizedText = "Synthetic recognized text"
    let secondItem = DashboardOCRImageItem(
      candidate: imageCandidate(
        sourceName: "Synthetic file.png",
        sourceDetail: "/tmp/synthetic-files",
        fingerprint: "duplicate-image"
      )
    )

    _ = store.record([firstItem])
    let recents = store.record([secondItem])
    let recent = try #require(recents.first)

    #expect(recent.recognizedText == "Synthetic recognized text")
    #expect(
      recent.sourceMetadata.map(\.name) == [
        "Synthetic clipboard.png",
        "Synthetic file.png",
      ]
    )
    #expect(
      recent.sourceMetadata.compactMap(\.detail) == [
        "/tmp/synthetic-clipboard",
        "/tmp/synthetic-files",
      ]
    )
  }

  @Test("Pending clipboard OCR keeps first same source policy decision")
  func pendingClipboardOCRKeepsFirstSameSourcePolicyDecision() throws {
    DashboardDebuggingOCRPasteboardRequests.resetForTesting()
    defer { DashboardDebuggingOCRPasteboardRequests.resetForTesting() }
    let firstPolicy = clipboardPolicy(id: "synthetic.clipboard.first", name: "First Synthetic OCR")
    let secondPolicy = clipboardPolicy(
      id: "synthetic.clipboard.second", name: "Second Synthetic OCR")
    let firstDecision = AutomationPolicyDecision(policy: firstPolicy, isAllowed: true, reason: nil)
    let secondDecision = AutomationPolicyDecision(
      policy: secondPolicy, isAllowed: true, reason: nil)

    DashboardDebuggingOCRPasteboardRequests.requestAutomationClipboard(
      candidates: [
        imageCandidate(sourceName: "Synthetic first.png", fingerprint: "shared")
      ],
      policyDecision: firstDecision
    )
    DashboardDebuggingOCRPasteboardRequests.requestAutomationClipboard(
      candidates: [
        imageCandidate(sourceName: "Synthetic second.png", fingerprint: "shared")
      ],
      policyDecision: secondDecision
    )

    let request = try #require(
      DashboardDebuggingOCRPasteboardRequests.takePendingRequest(after: 0)
    )
    #expect(request.policyDecision == firstDecision)
    #expect(
      request.candidates.first?.sourceMetadata.map(\.name) == [
        "Synthetic first.png",
        "Synthetic second.png",
      ]
    )
  }

  @Test("Automation event records decode old persisted payloads")
  func automationEventRecordsDecodeOldPersistedPayloads() throws {
    let data = Data(
      """
      {
        "source": "clipboard",
        "outcome": "matched"
      }
      """.utf8
    )

    let event = try JSONDecoder().decode(AutomationPolicyEventRecord.self, from: data)

    #expect(event.source == .clipboard)
    #expect(event.outcome == .matched)
    #expect(event.summary == "Clipboard")
    #expect(event.contentKinds == [.unknown])
    #expect(event.actions.isEmpty)
    #expect(event.postprocessors.isEmpty)
    #expect(event.trigger == "unknown")
    #expect(event.filePaths.isEmpty)
  }

  @Test("Screenshot watcher orders new files by newest modification time")
  func screenshotWatcherOrdersNewFilesByNewestModificationTime() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let oldURL = directory.appendingPathComponent("old-synthetic.png")
    let newURL = directory.appendingPathComponent("new-synthetic.png")
    try Data([1]).write(to: oldURL)
    try Data([2]).write(to: newURL)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 100)],
      ofItemAtPath: oldURL.path
    )
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 200)],
      ofItemAtPath: newURL.path
    )

    let ordered = DashboardOCRSystemScreenshotFolderWatcher.newestFirst([oldURL, newURL])

    #expect(ordered == [newURL, oldURL])
  }

  private func clipboardPolicy(id: String, name: String) -> AutomationPolicy {
    AutomationPolicy(
      id: id,
      name: name,
      eventSource: .clipboard,
      isEnabled: true,
      priority: 1,
      match: AutomationPolicyMatch(contentKinds: [.image]),
      preprocessors: [.dedupeByFingerprint],
      actions: [.ocrImage, .rememberRecentScan],
      postprocessors: [.persistResult, .auditEvent]
    )
  }

  private func imageCandidate(
    sourceName: String = "Synthetic image.png",
    sourceDetail: String? = "/tmp/synthetic-images",
    fingerprint: String = "synthetic-image"
  ) -> DashboardOCRImageCandidate {
    DashboardOCRImageCandidate(
      image: syntheticImage(),
      sourceName: sourceName,
      sourceDetail: sourceDetail,
      fingerprint: fingerprint
    )
  }

  private func syntheticImage() -> NSImage {
    let image = NSImage(size: NSSize(width: 16, height: 16))
    image.lockFocus()
    NSColor.systemGreen.setFill()
    NSRect(origin: .zero, size: image.size).fill()
    image.unlockFocus()
    return image
  }

  private func syntheticSourceApplication() -> AutomationSourceApplication {
    AutomationSourceApplication(
      bundleIdentifier: "com.example.synthetic-editor",
      localizedName: "Synthetic Editor",
      processIdentifier: 456,
      confidence: "test"
    )
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "DashboardDebuggingOCRGapBatch-\(UUID().uuidString)",
        isDirectory: true
      )
  }
}
