import AppKit
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard debugging OCR preview")
@MainActor
struct DashboardDebuggingOCRPreviewTests {
  @Test("Preview item preserves live scan source metadata and copyable paths")
  func previewItemPreservesLiveScanSourceMetadataAndCopyablePaths() {
    var item = DashboardOCRImageItem(
      candidate: DashboardOCRImageCandidate(
        image: syntheticImage(),
        sourceName: "Synthetic screenshot.png",
        sourceDetail: "/tmp/synthetic-screens",
        fingerprint: "synthetic-live-preview"
      )
    )
    item.mergeSourceMetadata(
      from: DashboardOCRImageCandidate(
        image: item.image,
        sourceName: "Clipboard image",
        sourceDetail: nil,
        fingerprint: item.fingerprint
      )
    )
    item.recognizedText = "Synthetic recognized text"

    let preview = DashboardOCRImagePreviewItem(item: item)

    #expect(preview.title == "Synthetic screenshot.png")
    #expect(preview.recognizedText == "Synthetic recognized text")
    #expect(preview.sourceMetadata.map(\.name) == ["Synthetic screenshot.png", "Clipboard image"])
    #expect(preview.copyableFilePaths == ["/tmp/synthetic-screens/Synthetic screenshot.png"])
    #expect(preview.showsSourceDetails)
  }

  @Test("Preview item preserves recent scan source metadata and scanned text")
  func previewItemPreservesRecentScanSourceMetadataAndScannedText() {
    let recentImage = DashboardOCRRecentImage(
      id: "synthetic-recent-preview",
      image: syntheticImage(),
      sourceName: "Synthetic recent.png",
      sourceDetail: "/tmp/synthetic-recents",
      sourceMetadata: [
        DashboardOCRImageSourceMetadata(
          name: "Synthetic recent.png",
          detail: "/tmp/synthetic-recents"
        ),
        DashboardOCRImageSourceMetadata(name: "Clipboard image", detail: nil),
      ],
      recognizedText: "Recent synthetic text",
      storedAt: Date(timeIntervalSince1970: 1_777_777_777)
    )

    let preview = DashboardOCRImagePreviewItem(recentImage: recentImage)

    #expect(preview.title == "Synthetic recent.png")
    #expect(preview.recognizedText == "Recent synthetic text")
    #expect(preview.sourceMetadata == recentImage.sourceMetadata)
    #expect(preview.copyableFilePaths == ["/tmp/synthetic-recents/Synthetic recent.png"])
    #expect(preview.showsSourceDetails)
  }

  @Test("Preview source details keep no-path single-source sizing unchanged")
  func previewSourceDetailsKeepNoPathSingleSourceSizingUnchanged() {
    let preview = DashboardOCRImagePreviewItem(
      item: DashboardOCRImageItem(
        candidate: DashboardOCRImageCandidate(
          image: syntheticImage(),
          sourceName: "Clipboard image",
          sourceDetail: nil,
          fingerprint: "synthetic-no-source-details"
        )
      )
    )

    let windowSize = preview.idealWindowSize(fitting: CGSize(width: 1_200, height: 900))

    #expect(!preview.showsSourceDetails)
    #expect(windowSize.width == 680)
    #expect(windowSize.height == 476)
  }

  @Test("Preview source details increase height only when useful metadata exists")
  func previewSourceDetailsIncreaseHeightOnlyWhenUsefulMetadataExists() {
    let basePreview = DashboardOCRImagePreviewItem(
      item: DashboardOCRImageItem(
        candidate: DashboardOCRImageCandidate(
          image: syntheticImage(),
          sourceName: "Clipboard image",
          sourceDetail: nil,
          fingerprint: "synthetic-base-preview"
        )
      )
    )
    let detailedPreview = DashboardOCRImagePreviewItem(
      item: DashboardOCRImageItem(
        candidate: DashboardOCRImageCandidate(
          image: syntheticImage(),
          sourceName: "Synthetic source.png",
          sourceDetail: "/tmp/synthetic-sources",
          fingerprint: "synthetic-detailed-preview"
        )
      )
    )

    let availableSize = CGSize(width: 1_200, height: 900)
    let baseWindowSize = basePreview.idealWindowSize(fitting: availableSize)
    let detailedWindowSize = detailedPreview.idealWindowSize(fitting: availableSize)

    #expect(detailedPreview.showsSourceDetails)
    #expect(detailedWindowSize.width == baseWindowSize.width)
    #expect(detailedWindowSize.height > baseWindowSize.height)
    #expect(detailedWindowSize.height < availableSize.height)
  }

  private func syntheticImage() -> NSImage {
    NSImage(size: NSSize(width: 640, height: 360))
  }
}
