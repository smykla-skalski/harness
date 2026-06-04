import AppKit
import Testing

@testable import HarnessMonitorUIPreviewable

extension DashboardDebuggingOCRPolicyBatchTests {
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
}
