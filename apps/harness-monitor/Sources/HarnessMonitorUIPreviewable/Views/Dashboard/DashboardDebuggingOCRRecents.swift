import AppKit
import Foundation
import HarnessMonitorKit
import SwiftUI

struct DashboardOCRRecentImage: Identifiable {
  let id: String
  let image: NSImage
  let sourceName: String
  let sourceDetail: String?
  let sourceMetadata: [DashboardOCRImageSourceMetadata]
  let storedAt: Date
}

@MainActor
final class DashboardOCRRecentImageStore {
  static let shared = DashboardOCRRecentImageStore()

  private let directoryURL: URL
  private let manifestURL: URL
  private let maxItems: Int
  private let fileManager: FileManager

  init(
    directoryURL: URL = HarnessMonitorPaths.generatedCacheRoot()
      .appendingPathComponent("debugging-ocr-recents", isDirectory: true),
    maxItems: Int = 8,
    fileManager: FileManager = .default
  ) {
    self.directoryURL = directoryURL
    manifestURL = directoryURL.appendingPathComponent("manifest.json")
    self.maxItems = max(0, maxItems)
    self.fileManager = fileManager
  }

  func load() -> [DashboardOCRRecentImage] {
    let records = validRecords(from: readManifest().items)
    return recentImages(from: records)
  }

  @discardableResult
  func record(_ items: [DashboardOCRImageItem]) -> [DashboardOCRRecentImage] {
    guard !items.isEmpty else {
      return load()
    }

    ensureDirectoryExists()
    var records = validRecords(from: readManifest().items)

    for item in items.reversed() {
      guard persistImage(item.image, filename: filename(for: item.fingerprint)) else {
        continue
      }
      records.removeAll { $0.fingerprint == item.fingerprint }
      records.insert(
        DashboardOCRRecentImageRecord(
          fingerprint: item.fingerprint,
          filename: filename(for: item.fingerprint),
          sourceName: item.sourceName,
          sourceDetail: item.sourceDetail,
          sourceMetadata: item.sourceMetadata,
          storedAt: Date()
        ),
        at: 0
      )
    }

    records = Array(records.prefix(maxItems))
    writeManifest(DashboardOCRRecentImageManifest(items: records))
    removeUnreferencedImages(keeping: Set(records.map(\.filename)))
    return recentImages(from: records)
  }

  private func validRecords(
    from records: [DashboardOCRRecentImageRecord]
  ) -> [DashboardOCRRecentImageRecord] {
    var seenFingerprints = Set<String>()
    return records.compactMap { record in
      guard record.filename == filename(for: record.fingerprint) else {
        return nil
      }
      guard seenFingerprints.insert(record.fingerprint).inserted else {
        return nil
      }
      let imageURL = directoryURL.appendingPathComponent(record.filename)
      guard fileManager.fileExists(atPath: imageURL.path) else {
        return nil
      }
      return record
    }
  }

  private func recentImages(from records: [DashboardOCRRecentImageRecord])
    -> [DashboardOCRRecentImage]
  {
    records.compactMap { record in
      let imageURL = directoryURL.appendingPathComponent(record.filename)
      guard let image = NSImage(contentsOf: imageURL) else {
        return nil
      }
      return DashboardOCRRecentImage(
        id: record.fingerprint,
        image: image,
        sourceName: record.sourceName,
        sourceDetail: record.sourceDetail,
        sourceMetadata: record.sourceMetadata
          ?? [
            DashboardOCRImageSourceMetadata(name: record.sourceName, detail: record.sourceDetail)
          ],
        storedAt: record.storedAt
      )
    }
  }

  private func persistImage(_ image: NSImage, filename: String) -> Bool {
    guard let data = image.dashboardOCRPNGData else {
      return false
    }
    let imageURL = directoryURL.appendingPathComponent(filename)
    do {
      try data.write(to: imageURL, options: .atomic)
      return true
    } catch {
      return false
    }
  }

  private func readManifest() -> DashboardOCRRecentImageManifest {
    guard
      let data = try? Data(contentsOf: manifestURL),
      let manifest = try? JSONDecoder().decode(DashboardOCRRecentImageManifest.self, from: data)
    else {
      return DashboardOCRRecentImageManifest(items: [])
    }
    return manifest
  }

  private func writeManifest(_ manifest: DashboardOCRRecentImageManifest) {
    ensureDirectoryExists()
    guard let data = try? JSONEncoder().encode(manifest) else {
      return
    }
    try? data.write(to: manifestURL, options: .atomic)
  }

  private func ensureDirectoryExists() {
    try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
  }

  private func removeUnreferencedImages(keeping filenames: Set<String>) {
    guard
      let urls = try? fileManager.contentsOfDirectory(
        at: directoryURL,
        includingPropertiesForKeys: nil
      )
    else {
      return
    }
    for url in urls where url.pathExtension == "png" && !filenames.contains(url.lastPathComponent) {
      try? fileManager.removeItem(at: url)
    }
  }

  private func filename(for fingerprint: String) -> String {
    let safeStem = fingerprint.unicodeScalars.map { scalar -> String in
      CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "-"
    }.joined()
    return "\(safeStem).png"
  }
}

private struct DashboardOCRRecentImageManifest: Codable {
  var items: [DashboardOCRRecentImageRecord]
}

private struct DashboardOCRRecentImageRecord: Codable, Equatable {
  let fingerprint: String
  let filename: String
  let sourceName: String
  let sourceDetail: String?
  let sourceMetadata: [DashboardOCRImageSourceMetadata]?
  let storedAt: Date
}

extension NSImage {
  fileprivate var dashboardOCRPNGData: Data? {
    guard
      let tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiffRepresentation)
    else {
      return nil
    }
    return bitmap.representation(using: .png, properties: [:])
  }
}

struct DashboardOCRRecentImagesSection: View {
  let images: [DashboardOCRRecentImage]
  let onSelect: (DashboardOCRRecentImage) -> Void

  fileprivate static let tileWidth: CGFloat = 136
  fileprivate static let tileHeight: CGFloat = 84

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text("Recent")
        .scaledFont(.subheadline)
        .foregroundStyle(.secondary)

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: HarnessMonitorTheme.spacingSM) {
          ForEach(images) { image in
            DashboardOCRRecentImageTile(image: image) {
              onSelect(image)
            }
          }
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardDebuggingOCRRecentSection)
  }
}

private struct DashboardOCRRecentImageTile: View {
  let image: DashboardOCRRecentImage
  let onSelect: () -> Void

  var body: some View {
    Button(action: onSelect) {
      Image(nsImage: image.image)
        .resizable()
        .interpolation(.high)
        .aspectRatio(contentMode: .fill)
        .frame(
          width: DashboardOCRRecentImagesSection.tileWidth,
          height: DashboardOCRRecentImagesSection.tileHeight
        )
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM))
        .overlay {
          RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM)
            .strokeBorder(HarnessMonitorTheme.controlBorder.opacity(0.42), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM))
    }
    .harnessInteractiveCardButtonStyle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(image.sourceName)
    .accessibilityHint("Open recent image details")
  }
}
