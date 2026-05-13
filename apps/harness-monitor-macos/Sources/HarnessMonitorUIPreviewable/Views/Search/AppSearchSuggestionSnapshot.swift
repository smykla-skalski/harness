import HarnessMonitorKit

/// Compact value snapshot rendered by the session search suggestion overlay.
///
/// The toolbar host builds this once per debounced result set so the
/// suggestion view does not read the observable `AppSearchModel` in its body.
public struct AppSearchSuggestionSnapshot: Equatable, Sendable {
  public static let empty = Self(rows: [])

  public let rows: [AppSearchSuggestionRow]

  public init(results: AppSearchResults) {
    self.init(
      rows: results.sections.flatMap { section in
        section.hits.map { hit in
          AppSearchSuggestionRow(sectionDomain: section.domain, hit: hit)
        }
      }
    )
  }

  public init(rows: [AppSearchSuggestionRow]) {
    self.rows = rows
  }

  public var firstHit: AppSearchHit? {
    rows.first?.hit
  }

  public func hit(matchingCompletion completion: String) -> AppSearchHit? {
    let trimmed = completion.trimmingCharacters(in: .whitespacesAndNewlines)
    return rows.first { row in
      row.completion == trimmed || row.displayTitle == trimmed
    }?.hit
  }

  public func hit(matchingDisplayTitle displayTitle: String) -> AppSearchHit? {
    let trimmed = displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    return rows.first { row in
      row.displayTitle == trimmed
    }?.hit
  }
}

public struct AppSearchSuggestionRow: Identifiable, Equatable, Sendable {
  public let id: String
  public let displayTitle: String
  public let completion: String
  public let hit: AppSearchHit

  public init(sectionDomain: AppSearchDomain, hit: AppSearchHit) {
    id = "\(sectionDomain.rawValue):\(hit.id)"
    displayTitle = "\(hit.title) (\(sectionDomain.label))"
    completion = hit.title
    self.hit = hit
  }
}
