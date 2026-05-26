import AppKit
import Foundation

struct DashboardOCRImageSourceMetadata: Codable, Equatable, Sendable {
  let name: String
  let detail: String?

  var key: String {
    "\(name)\u{1f}\(detail ?? "")"
  }

  var copyableFilePath: String? {
    guard let detail, !detail.isEmpty else {
      return nil
    }
    if let url = URL(string: detail), url.isFileURL {
      return url.appendingPathComponent(name).path
    }
    guard detail.hasPrefix("/") else {
      return nil
    }
    return URL(fileURLWithPath: detail).appendingPathComponent(name).path
  }
}

struct DashboardOCRImageCandidate {
  let image: NSImage
  let sourceName: String
  let sourceDetail: String?
  let fingerprint: String
  let sourceMetadata: [DashboardOCRImageSourceMetadata]

  init(
    image: NSImage,
    sourceName: String,
    sourceDetail: String?,
    fingerprint: String,
    sourceMetadata: [DashboardOCRImageSourceMetadata] = []
  ) {
    self.image = image
    self.sourceName = sourceName
    self.sourceDetail = sourceDetail
    self.fingerprint = fingerprint
    self.sourceMetadata = Self.deduplicatedSourceMetadata(
      sourceMetadata
        + [DashboardOCRImageSourceMetadata(name: sourceName, detail: sourceDetail)]
    )
  }

  func mergingSourceMetadata(from other: Self) -> Self {
    Self(
      image: image,
      sourceName: sourceName,
      sourceDetail: sourceDetail,
      fingerprint: fingerprint,
      sourceMetadata: sourceMetadata + other.sourceMetadata
    )
  }

  static func mergedByFingerprint(
    _ candidates: [Self]
  ) -> [Self] {
    var mergedCandidates: [Self] = []
    var indexesByFingerprint: [String: Int] = [:]

    for candidate in candidates {
      if let index = indexesByFingerprint[candidate.fingerprint] {
        mergedCandidates[index] = mergedCandidates[index].mergingSourceMetadata(from: candidate)
        continue
      }
      indexesByFingerprint[candidate.fingerprint] = mergedCandidates.count
      mergedCandidates.append(candidate)
    }

    return mergedCandidates
  }

  private static func deduplicatedSourceMetadata(
    _ metadata: [DashboardOCRImageSourceMetadata]
  ) -> [DashboardOCRImageSourceMetadata] {
    var seenKeys = Set<String>()
    return metadata.filter { source in
      seenKeys.insert(source.key).inserted
    }
  }
}

extension Array where Element == DashboardOCRImageSourceMetadata {
  var copyableFilePaths: [String] {
    var seenPaths = Set<String>()
    return compactMap(\.copyableFilePath).filter { path in
      seenPaths.insert(path).inserted
    }
  }
}
