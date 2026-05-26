import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard debugging OCR")
@MainActor
struct DashboardDebuggingOCRTests {
  @Test("Clipboard item with file URL and image data is processed once")
  func clipboardItemWithFileURLAndImageDataIsProcessedOnce() throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("ocr.test.\(UUID().uuidString)"))
    defer { pasteboard.clearContents() }
    let imageURL = try makeImagePasteboardItem(on: pasteboard)
    defer { try? FileManager.default.removeItem(at: imageURL.deletingLastPathComponent()) }

    let candidates = DashboardOCRInputReader.candidates(fromPasteboard: pasteboard)

    #expect(candidates.count == 1)
    #expect(candidates.first?.sourceName == imageURL.lastPathComponent)
  }

  @Test("Pasteboard request queues deduplicated clipboard images")
  func pasteboardRequestQueuesDeduplicatedClipboardImages() throws {
    DashboardDebuggingOCRPasteboardRequests.resetForTesting()
    defer { DashboardDebuggingOCRPasteboardRequests.resetForTesting() }
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("ocr.request.\(UUID().uuidString)"))
    defer { pasteboard.clearContents() }
    let imageURL = try makeImagePasteboardItem(on: pasteboard)
    defer { try? FileManager.default.removeItem(at: imageURL.deletingLastPathComponent()) }

    let didQueue = DashboardDebuggingOCRPasteboardRequests.requestPaste(
      fromPasteboard: pasteboard
    )
    let request = try #require(
      DashboardDebuggingOCRPasteboardRequests.takePendingRequest(after: 0)
    )

    #expect(didQueue)
    #expect(request.candidates.count == 1)
    #expect(
      DashboardDebuggingOCRPasteboardRequests.takePendingRequest(after: request.id) == nil
    )
  }

  @Test("Concrete PNG item provider is processed as an image")
  func concretePNGItemProviderIsProcessedAsImage() async throws {
    let data = try makeImageData(fileType: .png)
    let provider = NSItemProvider(item: data as NSData, typeIdentifier: UTType.png.identifier)

    #expect(DashboardOCRInputReader.providerCanProvideImage(provider))
    let candidates = await DashboardOCRInputReader.candidates(from: [provider])

    #expect(candidates.count == 1)
    #expect(candidates.first?.sourceName == "Dropped image")
  }

  @Test("Transferable paste images queue candidates")
  func transferablePasteImagesQueueCandidates() throws {
    DashboardDebuggingOCRPasteboardRequests.resetForTesting()
    defer { DashboardDebuggingOCRPasteboardRequests.resetForTesting() }
    let transferImage = DashboardOCRTransferImage(
      data: try makeImageData(fileType: .png),
      sourceName: "transfer.png",
      sourceDetail: nil
    )

    let didQueue = DashboardDebuggingOCRPasteboardRequests.requestPaste(from: [transferImage])
    let request = try #require(
      DashboardDebuggingOCRPasteboardRequests.takePendingRequest(after: 0)
    )

    #expect(didQueue)
    #expect(request.candidates.count == 1)
    #expect(request.candidates.first?.sourceName == "transfer.png")
  }

  @Test("Near simultaneous paste paths deduplicate matching images and merge metadata")
  func nearSimultaneousPastePathsDeduplicateMatchingImagesAndMergeMetadata() throws {
    DashboardDebuggingOCRPasteboardRequests.resetForTesting()
    defer { DashboardDebuggingOCRPasteboardRequests.resetForTesting() }
    let data = try makeImageData(fileType: .png)
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("ocr.duplicate.\(UUID().uuidString)"))
    defer { pasteboard.clearContents() }
    let imageURL = try makeImagePasteboardItem(
      on: pasteboard,
      data: data,
      fileExtension: "png",
      pasteboardType: .png
    )
    defer { try? FileManager.default.removeItem(at: imageURL.deletingLastPathComponent()) }
    let transferImage = DashboardOCRTransferImage(
      data: data,
      sourceName: "transfer.png",
      sourceDetail: nil
    )

    let firstDidQueue = DashboardDebuggingOCRPasteboardRequests.requestPaste(
      fromPasteboard: pasteboard
    )
    let duplicateDidQueue = DashboardDebuggingOCRPasteboardRequests.requestPaste(
      from: [transferImage]
    )
    let request = try #require(
      DashboardDebuggingOCRPasteboardRequests.takePendingRequest(after: 0)
    )

    #expect(firstDidQueue)
    #expect(duplicateDidQueue)
    #expect(request.candidates.count == 1)
    let candidate = try #require(request.candidates.first)
    #expect(candidate.fingerprint == transferImage.candidate?.fingerprint)
    #expect(
      candidate.sourceMetadata.map(\.name) == [imageURL.lastPathComponent, "transfer.png"]
    )
  }

  @Test("Candidate fingerprint dedupe preserves every source metadata descriptor")
  func candidateFingerprintDedupePreservesEverySourceMetadataDescriptor() throws {
    let data = try makeImageData(fileType: .png)
    let image = try #require(NSImage(data: data))
    let fingerprint = DashboardOCRImageFingerprint.make(data: data)
    let candidates = [
      DashboardOCRImageCandidate(
        image: image,
        sourceName: "Slack 2026-05-26.png",
        sourceDetail: "/Users/bart/Desktop",
        fingerprint: fingerprint
      ),
      DashboardOCRImageCandidate(
        image: image,
        sourceName: "Clipboard image",
        sourceDetail: nil,
        fingerprint: fingerprint
      ),
    ]

    let merged = DashboardOCRImageCandidate.mergedByFingerprint(candidates)

    #expect(merged.count == 1)
    #expect(
      merged.first?.sourceMetadata == [
        DashboardOCRImageSourceMetadata(
          name: "Slack 2026-05-26.png",
          detail: "/Users/bart/Desktop"
        ),
        DashboardOCRImageSourceMetadata(name: "Clipboard image", detail: nil),
      ]
    )
  }

  @Test("Source metadata builds copyable file paths")
  func sourceMetadataBuildsCopyableFilePaths() {
    let metadata = [
      DashboardOCRImageSourceMetadata(name: "screenshot.png", detail: "/tmp/screens"),
      DashboardOCRImageSourceMetadata(name: "screenshot.png", detail: "/tmp/screens"),
      DashboardOCRImageSourceMetadata(name: "Clipboard image", detail: nil),
    ]

    #expect(metadata.copyableFilePaths == ["/tmp/screens/screenshot.png"])
  }

  @Test("Recent image store persists newest images and prunes older files")
  func recentImageStorePersistsNewestImagesAndPrunesOlderFiles() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "DashboardDebuggingOCRRecents-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DashboardOCRRecentImageStore(directoryURL: directory, maxItems: 2)
    let first = try makeImageItem(name: "first.png", color: .systemBlue)
    let second = try makeImageItem(name: "second.png", color: .systemGreen)
    let third = try makeImageItem(
      name: "third.png",
      color: .systemRed,
      recognizedText: "recognized text"
    )

    _ = store.record([first])
    _ = store.record([second])
    let recents = store.record([third])

    #expect(recents.map(\.sourceName) == ["third.png", "second.png"])
    #expect(store.load().map(\.sourceName) == ["third.png", "second.png"])
    #expect(store.load().first?.sourceMetadata.map(\.name) == ["third.png"])
    #expect(store.load().first?.recognizedText == "recognized text")

    let persistedImages = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "png" }

    #expect(persistedImages.count == 2)
    #expect(
      persistedImages.contains {
        $0.lastPathComponent.contains(first.fingerprint.replacingOccurrences(of: ":", with: "-"))
      } == false
    )
  }

  @Test("Preview window size follows image size instead of always using the full screen")
  func previewWindowSizeFollowsImageSizeInsteadOfAlwaysUsingFullScreen() {
    let image = NSImage(size: NSSize(width: 640, height: 360))
    let preview = DashboardOCRImagePreviewItem(
      item: DashboardOCRImageItem(
        candidate: DashboardOCRImageCandidate(
          image: image,
          sourceName: "preview.png",
          sourceDetail: nil,
          fingerprint: "preview"
        )
      )
    )

    let windowSize = preview.idealWindowSize(fitting: CGSize(width: 1_200, height: 900))

    #expect(windowSize.width == 680)
    #expect(windowSize.height == 476)
  }

  @Test("Preview window size caps scanned text height below the image")
  func previewWindowSizeCapsScannedTextHeightBelowImage() {
    let image = NSImage(size: NSSize(width: 640, height: 360))
    var item = DashboardOCRImageItem(
      candidate: DashboardOCRImageCandidate(
        image: image,
        sourceName: "preview.png",
        sourceDetail: nil,
        fingerprint: "preview"
      )
    )
    item.recognizedText = Array(repeating: "Slack message text", count: 120)
      .joined(separator: "\n")
    let preview = DashboardOCRImagePreviewItem(item: item)

    let windowSize = preview.idealWindowSize(fitting: CGSize(width: 1_200, height: 900))

    #expect(windowSize.width == 680)
    #expect(windowSize.height > 476)
    #expect(windowSize.height < 800)
  }

  @discardableResult
  private func makeImagePasteboardItem(
    on pasteboard: NSPasteboard,
    data: Data? = nil,
    fileExtension: String = "tiff",
    pasteboardType: NSPasteboard.PasteboardType = .tiff
  ) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("DashboardDebuggingOCRTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let imageURL = directory.appendingPathComponent("sample.\(fileExtension)")
    let imageData = try data ?? makeImageData()
    try imageData.write(to: imageURL)

    let item = NSPasteboardItem()
    _ = item.setString(imageURL.absoluteString, forType: .fileURL)
    _ = item.setData(imageData, forType: pasteboardType)
    pasteboard.clearContents()
    _ = pasteboard.writeObjects([item])
    return imageURL
  }

  private func makeImageItem(
    name: String,
    color: NSColor,
    recognizedText: String = ""
  ) throws -> DashboardOCRImageItem {
    let data = try makeImageData(fileType: .png, color: color)
    let image = try #require(NSImage(data: data))
    var item = DashboardOCRImageItem(
      candidate: DashboardOCRImageCandidate(
        image: image,
        sourceName: name,
        sourceDetail: "/tmp",
        fingerprint: DashboardOCRImageFingerprint.make(data: data)
      )
    )
    item.recognizedText = recognizedText
    item.status = recognizedText.isEmpty ? .empty : .recognized
    return item
  }

  private func makeImageData(
    fileType: NSBitmapImageRep.FileType = .tiff,
    color: NSColor = .systemBlue
  ) throws -> Data {
    let image = NSImage(size: NSSize(width: 8, height: 8))
    image.lockFocus()
    color.setFill()
    NSRect(x: 0, y: 0, width: 8, height: 8).fill()
    image.unlockFocus()
    let tiffData = try #require(image.tiffRepresentation)
    guard fileType != .tiff else {
      return tiffData
    }
    let bitmap = try #require(NSBitmapImageRep(data: tiffData))
    return try #require(bitmap.representation(using: fileType, properties: [:]))
  }
}
