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

  @Test("Near simultaneous paste paths deduplicate matching images")
  func nearSimultaneousPastePathsDeduplicateMatchingImages() throws {
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
    #expect(!duplicateDidQueue)
    #expect(request.candidates.count == 1)
    #expect(request.candidates.first?.fingerprint == transferImage.candidate?.fingerprint)
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

  private func makeImageData(fileType: NSBitmapImageRep.FileType = .tiff) throws -> Data {
    let image = NSImage(size: NSSize(width: 8, height: 8))
    image.lockFocus()
    NSColor.systemBlue.setFill()
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
