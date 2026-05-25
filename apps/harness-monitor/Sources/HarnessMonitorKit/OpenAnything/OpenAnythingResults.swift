public struct OpenAnythingSection: Identifiable, Hashable, Sendable {
  public let id: String
  public let domain: OpenAnythingDomain
  public let title: String
  public let systemImage: String
  public let totalCount: Int?
  public let hits: [OpenAnythingHit]

  public init(
    id: String? = nil,
    domain: OpenAnythingDomain,
    title: String? = nil,
    systemImage: String? = nil,
    totalCount: Int? = nil,
    hits: [OpenAnythingHit]
  ) {
    self.id = id ?? domain.rawValue
    self.domain = domain
    self.title = title ?? domain.label
    self.systemImage = systemImage ?? domain.systemImage
    self.totalCount = totalCount
    self.hits = hits
  }
}

struct OpenAnythingHitLocation: Hashable, Sendable {
  let sectionIndex: Int
  let hitIndex: Int
  let resultIndex: Int
}

private struct OpenAnythingNavigationSnapshot {
  let firstHit: OpenAnythingHit?
  let hitIDs: [String]
  let hitLocationsByID: [String: OpenAnythingHitLocation]
}

public struct OpenAnythingResults: Hashable, Sendable {
  public let query: String
  public let sections: [OpenAnythingSection]
  public let hitCount: Int
  public let hasExactlyOneHit: Bool
  /// Per-domain match counts before the per-section cap is applied. Lets
  /// section headers show "Show all (N)" with the real total without forcing
  /// the view to know about the limit.
  public let domainTotals: [OpenAnythingDomain: Int]

  let firstHit: OpenAnythingHit?
  let hitIDs: [String]
  let hitLocationsByID: [String: OpenAnythingHitLocation]

  public static let empty = Self(query: "", sections: [], domainTotals: [:])

  public init(
    query: String,
    sections: [OpenAnythingSection],
    domainTotals: [OpenAnythingDomain: Int] = [:]
  ) {
    self.query = query
    self.sections = sections
    let navigation = Self.navigationSnapshot(in: sections)
    hitCount = navigation.hitIDs.count
    hasExactlyOneHit = navigation.hitIDs.count == 1
    firstHit = navigation.firstHit
    hitIDs = navigation.hitIDs
    hitLocationsByID = navigation.hitLocationsByID
    self.domainTotals = domainTotals
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.query == rhs.query
      && lhs.sections == rhs.sections
      && lhs.domainTotals == rhs.domainTotals
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(query)
    hasher.combine(sections)
    hasher.combine(domainTotals)
  }

  public var allHits: [OpenAnythingHit] {
    sections.flatMap(\.hits)
  }

  public var isEmpty: Bool {
    sections.isEmpty
  }

  public func totalCount(for domain: OpenAnythingDomain) -> Int {
    domainTotals[domain]
      ?? sections.first(where: { $0.domain == domain })?.hits.count
      ?? 0
  }

  public func totalCount(for section: OpenAnythingSection) -> Int {
    section.totalCount ?? totalCount(for: section.domain)
  }

  private static func navigationSnapshot(
    in sections: [OpenAnythingSection]
  ) -> OpenAnythingNavigationSnapshot {
    let expectedHitCount = sections.reduce(into: 0) { count, section in
      count += section.hits.count
    }
    var firstHit: OpenAnythingHit?
    var hitIDs: [String] = []
    hitIDs.reserveCapacity(expectedHitCount)
    var hitLocationsByID: [String: OpenAnythingHitLocation] = [:]
    hitLocationsByID.reserveCapacity(expectedHitCount)

    for sectionIndex in sections.indices {
      for hitIndex in sections[sectionIndex].hits.indices {
        let hit = sections[sectionIndex].hits[hitIndex]
        if firstHit == nil {
          firstHit = hit
        }
        hitIDs.append(hit.id)
        hitLocationsByID[hit.id] = OpenAnythingHitLocation(
          sectionIndex: sectionIndex,
          hitIndex: hitIndex,
          resultIndex: hitIDs.count - 1
        )
      }
    }

    return OpenAnythingNavigationSnapshot(
      firstHit: firstHit,
      hitIDs: hitIDs,
      hitLocationsByID: hitLocationsByID
    )
  }
}
