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
  let recognizedText: String
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
          recognizedText: item.recognizedText,
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
        recognizedText: record.recognizedText ?? "",
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
  let recognizedText: String?
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
  fileprivate static let hoverScale: CGFloat = 1.035
  fileprivate static let hoverOutset: CGFloat = 8

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
      .contentMargins(.horizontal, Self.hoverOutset, for: .scrollContent)
      .contentMargins(.vertical, Self.hoverOutset, for: .scrollContent)
      .scrollClipDisabled()
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardDebuggingOCRRecentSection)
  }
}

private struct DashboardOCRRecentImageTile: View {
  let image: DashboardOCRRecentImage
  let onSelect: () -> Void
  @State private var isHovered = false

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
            .strokeBorder(
              isHovered
                ? HarnessMonitorTheme.accent.opacity(0.74)
                : HarnessMonitorTheme.controlBorder.opacity(0.42),
              lineWidth: isHovered ? 1.5 : 1
            )
        }
        .overlay {
          RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM)
            .fill(
              isHovered
                ? HarnessMonitorTheme.accent.opacity(0.08)
                : Color.clear
            )
        }
        .contentShape(RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM))
    }
    .buttonStyle(DashboardOCRRecentImageButtonStyle(isHovered: isHovered))
    .onHover { hovering in
      isHovered = hovering
    }
    .pointerStyle(.link)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(image.sourceName)
    .accessibilityHint("Open recent image details")
  }
}

private struct DashboardOCRRecentImageButtonStyle: ButtonStyle {
  let isHovered: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(
        configuration.isPressed
          ? 0.965
          : isHovered ? DashboardOCRRecentImagesSection.hoverScale : 1
      )
      .shadow(
        color: isHovered || configuration.isPressed
          ? HarnessMonitorTheme.accent.opacity(configuration.isPressed ? 0.16 : 0.22)
          : .clear,
        radius: configuration.isPressed ? 5 : 10,
        y: configuration.isPressed ? 2 : 5
      )
      .brightness(configuration.isPressed ? -0.035 : isHovered ? 0.028 : 0)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
      .animation(.easeOut(duration: 0.16), value: isHovered)
  }
}
