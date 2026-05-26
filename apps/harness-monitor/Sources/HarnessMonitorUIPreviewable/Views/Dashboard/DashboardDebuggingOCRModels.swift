import AppKit
import Foundation

struct DashboardOCRImageSourceMetadata: Codable, Equatable, Sendable {
  let name: String
  let detail: String?

  var key: String {
    "\(name)\u{1f}\(detail ?? "")"
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
