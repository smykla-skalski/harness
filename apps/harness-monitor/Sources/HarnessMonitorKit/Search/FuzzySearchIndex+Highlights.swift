import Fuse

private struct FuzzySearchHighlightAccumulator {
  private var title: [SearchHighlightRange] = []
  private var subtitle: [SearchHighlightRange] = []
  private var trailing: [SearchHighlightRange] = []

  mutating func append(
    _ ranges: [SearchHighlightRange],
    field: SearchHighlightField
  ) {
    switch field {
    case .title:
      title.append(contentsOf: ranges)
    case .subtitle:
      subtitle.append(contentsOf: ranges)
    case .trailing:
      trailing.append(contentsOf: ranges)
    }
  }

  func results() -> SearchHighlights {
    SearchHighlights(
      title: Self.mergedRanges(title),
      subtitle: Self.mergedRanges(subtitle),
      trailing: Self.mergedRanges(trailing)
    )
  }

  private static func mergedRanges(
    _ ranges: [SearchHighlightRange]
  ) -> [SearchHighlightRange] {
    guard !ranges.isEmpty else { return [] }
    let sorted = ranges.sorted {
      if $0.start != $1.start {
        return $0.start < $1.start
      }
      return $0.end < $1.end
    }
    var merged: [SearchHighlightRange] = []
    merged.reserveCapacity(sorted.count)
    for range in sorted {
      guard let last = merged.last else {
        merged.append(range)
        continue
      }
      if range.start <= last.end + 1 {
        merged[merged.count - 1] = SearchHighlightRange(
          start: last.start,
          end: max(last.end, range.end)
        )
      } else {
        merged.append(range)
      }
    }
    return merged
  }
}

extension FuzzySearchIndex {
  func highlights(
    from matches: [FuseMatch]?,
    fallbackQuery query: String,
    item: Element
  ) -> SearchHighlights {
    if let matches {
      return highlights(from: matches)
    }
    return highlights(for: item, query: query)
  }

  private func highlights(from matches: [FuseMatch]) -> SearchHighlights {
    var highlights = FuzzySearchHighlightAccumulator()
    for match in matches {
      guard case .string(let keyName)? = match.key else { continue }
      guard let field = fieldsByName[keyName], let highlightField = field.highlightField else {
        continue
      }
      let ranges = match.indices.map { SearchHighlightRange(start: $0.start, end: $0.end) }
      highlights.append(ranges, field: highlightField)
    }
    return highlights.results()
  }

  private func highlights(for item: Element, query: String) -> SearchHighlights {
    guard !highlightFields.isEmpty else { return .empty }
    var highlights = FuzzySearchHighlightAccumulator()
    for field in highlightFields {
      switch field.accessor {
      case .single(let get):
        appendHighlights(
          in: get(item),
          query: query,
          field: field.highlightField,
          to: &highlights
        )
      case .multiple(let get):
        for value in get(item) {
          appendHighlights(
            in: value,
            query: query,
            field: field.highlightField,
            to: &highlights
          )
        }
      }
    }
    return highlights.results()
  }

  private func appendHighlights(
    in value: String?,
    query: String,
    field: SearchHighlightField?,
    to highlights: inout FuzzySearchHighlightAccumulator
  ) {
    guard let value, let field else { return }
    let outcome = Fuse.match(query, in: value, options: highlightOptions)
    guard outcome.isMatch, let indices = outcome.indices else { return }
    let ranges = indices.map { SearchHighlightRange(start: $0.start, end: $0.end) }
    highlights.append(ranges, field: field)
  }
}
