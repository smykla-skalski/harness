import CoreTransferable
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct FullParityTextPasteItem: Transferable, Equatable, Sendable {
    let text: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .plainText) { data in
            Self(text: String(data: data, encoding: .utf8) ?? "")
        }
    }
}

struct FullParityImagePasteItem: Transferable, Sendable {
    let data: Data
    let sourceName: String
    let sourceDetail: String?

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(
            importedContentType: .image,
            shouldAttemptToOpenInPlace: true
        ) { file in
            try Self(fileURL: file.file)
        }
        DataRepresentation(importedContentType: .png) { data in
            Self.pastedImage(data)
        }
        DataRepresentation(importedContentType: .jpeg) { data in
            Self.pastedImage(data)
        }
        DataRepresentation(importedContentType: .tiff) { data in
            Self.pastedImage(data)
        }
        DataRepresentation(importedContentType: .heic) { data in
            Self.pastedImage(data)
        }
    }

    private init(data: Data, sourceName: String, sourceDetail: String?) {
        self.data = data
        self.sourceName = sourceName
        self.sourceDetail = sourceDetail
    }

    private init(fileURL: URL) throws {
        data = try Data(contentsOf: fileURL)
        sourceName =
            fileURL.lastPathComponent.isEmpty
                ? "Image file" : fileURL.lastPathComponent
        sourceDetail = fileURL.deletingLastPathComponent().path
    }

    private static func pastedImage(_ data: Data) -> Self {
        Self(data: data, sourceName: "Pasted image", sourceDetail: nil)
    }
}

extension View {
    func fullParityAncestorTransferReceivers() -> some View {
        modifier(FullParityAncestorTextPasteDestination())
            .modifier(FullParityAncestorImagePasteDestination())
    }
}

struct FullParityAncestorTextPasteDestination: ViewModifier {
    func body(content: Content) -> some View {
        content
            .pasteDestination(for: FullParityTextPasteItem.self) { items in
                LabTrace.emit(
                    "full-parity.ancestor-paste.text",
                    fields: [
                        "items": String(items.count),
                        "nonEmpty": String(items.count { !$0.text.isEmpty }),
                    ]
                )
            }
    }
}

struct FullParityAncestorImagePasteDestination: ViewModifier {
    func body(content: Content) -> some View {
        content
            .pasteDestination(for: FullParityImagePasteItem.self) { items in
                LabTrace.emit(
                    "full-parity.ancestor-paste.image",
                    fields: [
                        "bytes": String(
                            items.reduce(0) { $0 + $1.data.count }
                        ),
                        "items": String(items.count),
                    ]
                )
            }
    }
}
