import AppKit
import Foundation
import Testing

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

  @discardableResult
  private func makeImagePasteboardItem(on pasteboard: NSPasteboard) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("DashboardDebuggingOCRTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let imageURL = directory.appendingPathComponent("sample.tiff")
    let image = NSImage(size: NSSize(width: 8, height: 8))
    image.lockFocus()
    NSColor.systemBlue.setFill()
    NSRect(x: 0, y: 0, width: 8, height: 8).fill()
    image.unlockFocus()
    let data = try #require(image.tiffRepresentation)
    try data.write(to: imageURL)

    let item = NSPasteboardItem()
    _ = item.setString(imageURL.absoluteString, forType: .fileURL)
    _ = item.setData(data, forType: .tiff)
    pasteboard.clearContents()
    _ = pasteboard.writeObjects([item])
    return imageURL
  }
}
