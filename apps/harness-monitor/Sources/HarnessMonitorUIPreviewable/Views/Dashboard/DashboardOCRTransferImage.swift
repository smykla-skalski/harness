import AppKit
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

struct DashboardOCRTransferImage: Transferable {
  let data: Data
  let sourceName: String
  let sourceDetail: String?

  init(data: Data, sourceName: String, sourceDetail: String?) {
    self.data = data
    self.sourceName = sourceName
    self.sourceDetail = sourceDetail
  }

  @MainActor var candidate: DashboardOCRImageCandidate? {
    guard let image = NSImage(data: data) else {
      return nil
    }
    return DashboardOCRImageCandidate(
      image: image,
      sourceName: sourceName,
      sourceDetail: sourceDetail
    )
  }

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(importedContentType: .image, shouldAttemptToOpenInPlace: true) { file in
      try Self(fileURL: file.file)
    }
    DataRepresentation(importedContentType: .png) { data in
      Self(data: data, sourceName: "Pasted image", sourceDetail: nil)
    }
    DataRepresentation(importedContentType: .jpeg) { data in
      Self(data: data, sourceName: "Pasted image", sourceDetail: nil)
    }
    DataRepresentation(importedContentType: .tiff) { data in
      Self(data: data, sourceName: "Pasted image", sourceDetail: nil)
    }
    DataRepresentation(importedContentType: .heic) { data in
      Self(data: data, sourceName: "Pasted image", sourceDetail: nil)
    }
  }

  private init(fileURL: URL) throws {
    data = try Data(contentsOf: fileURL)
    sourceName =
      fileURL.lastPathComponent.isEmpty
      ? "Image file" : fileURL.lastPathComponent
    sourceDetail = fileURL.deletingLastPathComponent().path
  }
}
