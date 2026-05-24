import Foundation
import SwiftData

@Model
public final class CachedReviewRepositoryLabels {
  #Unique<CachedReviewRepositoryLabels>([\.repository])
  #Index<CachedReviewRepositoryLabels>([\.repository], [\.cachedAt])

  public var repository: String
  public var cachedAt: Date
  public var labelsData: Data

  public init(
    repository: String,
    cachedAt: Date = .now,
    labelsData: Data = Data()
  ) {
    self.repository = repository
    self.cachedAt = cachedAt
    self.labelsData = labelsData
  }
}

extension CachedReviewRepositoryLabels {
  static func make(
    repository: String,
    labels: [ReviewRepositoryLabel]
  ) throws -> CachedReviewRepositoryLabels {
    try CachedReviewRepositoryLabels(
      repository: repository,
      labelsData: Codecs.encoder.encode(labels)
    )
  }

  func update(labels: [ReviewRepositoryLabel]) throws {
    cachedAt = .now
    labelsData = try Codecs.encoder.encode(labels)
  }

  func decodedLabels() throws -> [ReviewRepositoryLabel] {
    guard !labelsData.isEmpty else { return [] }
    return try Codecs.decoder.decode([ReviewRepositoryLabel].self, from: labelsData)
  }
}
