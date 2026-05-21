import Foundation
import SwiftData

@Model
public final class CachedDependencyRepositoryLabels {
  #Unique<CachedDependencyRepositoryLabels>([\.repository])
  #Index<CachedDependencyRepositoryLabels>([\.repository], [\.cachedAt])

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

extension CachedDependencyRepositoryLabels {
  static func make(
    repository: String,
    labels: [DependencyUpdateRepositoryLabel]
  ) throws -> CachedDependencyRepositoryLabels {
    try CachedDependencyRepositoryLabels(
      repository: repository,
      labelsData: Codecs.encoder.encode(labels)
    )
  }

  func update(labels: [DependencyUpdateRepositoryLabel]) throws {
    cachedAt = .now
    labelsData = try Codecs.encoder.encode(labels)
  }

  func decodedLabels() throws -> [DependencyUpdateRepositoryLabel] {
    guard !labelsData.isEmpty else { return [] }
    return try Codecs.decoder.decode([DependencyUpdateRepositoryLabel].self, from: labelsData)
  }
}
