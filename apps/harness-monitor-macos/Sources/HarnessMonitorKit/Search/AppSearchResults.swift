import Foundation

/// The full search response for one query.
///
/// Sections are already ordered: the primary domain (the route the user is
/// currently on) appears first, then the rest by descending hit count and
/// stable domain order on ties. Empty sections are omitted.
public struct AppSearchResults: Hashable, Sendable {
  public let query: String
  public let primaryDomain: AppSearchDomain?
  public let sections: [AppSearchSection]

  public init(
    query: String,
    primaryDomain: AppSearchDomain?,
    sections: [AppSearchSection]
  ) {
    self.query = query
    self.primaryDomain = primaryDomain
    self.sections = sections
  }

  public static let empty = AppSearchResults(
    query: "",
    primaryDomain: nil,
    sections: []
  )

  public var totalHitCount: Int {
    sections.reduce(0) { $0 + $1.hits.count }
  }

  public var isEmpty: Bool {
    sections.isEmpty
  }
}
