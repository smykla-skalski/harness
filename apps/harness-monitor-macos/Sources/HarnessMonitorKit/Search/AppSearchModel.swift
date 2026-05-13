import Foundation

/// `@MainActor`-isolated façade over ``AppSearchIndex`` that owns the
/// observable state the search UI reads.
///
/// The split of responsibilities is:
///
/// - The view layer owns the bound `@State` query string and a
///   `.task(id: query)` debounce that calls ``runSearch(query:primary:)``
///   after a 150 ms quiet window.
/// - This model owns the resolved (post-debounce) `query`, the
///   `AppSearchResults` used by the suggestions popover and per-route
///   list filters, and the `isSearching` flag for the UI.
/// - The actor (``AppSearchIndex``) owns the corpora and the pure
///   search function.
///
/// Cancellation contract: `runSearch` checks `Task.isCancelled` after
/// awaiting the index, so a stale invocation cancelled by the caller's
/// `.task(id:)` never overwrites the most recent results.
@MainActor
@Observable
public final class AppSearchModel {
  /// The query that produced ``results``. Empty until the first
  /// non-empty post-debounce search lands. Trimmed of whitespace.
  public private(set) var query: String = ""

  /// The most recent search response. Sections are already ordered by
  /// the index (primary first, others canonical).
  public private(set) var results: AppSearchResults = .empty

  /// `true` between the start of a search and the moment the actor
  /// returns its result (or the search is cancelled mid-flight).
  public private(set) var isSearching: Bool = false

  /// `true` while the toolbar `.searchable` field is presented. Drives
  /// lazy reindexing so the four corpora are not rebuilt on every
  /// incoming timeline event when the search popover is closed.
  /// Lives on the model (not in `@Environment`) because the index
  /// updater modifier sits OUTSIDE the host modifier in the view tree
  /// and SwiftUI environment values flow downward only.
  public private(set) var isPresented: Bool = false

  /// Closure-based seam so tests can inject a controllable provider.
  /// Production binding wraps an ``AppSearchIndex`` reference.
  private let searchProvider: (String, AppSearchDomain?) async -> AppSearchResults

  public convenience init(index: AppSearchIndex) {
    self.init(searchProvider: { query, primary in
      await index.search(query: query, primary: primary)
    })
  }

  public init(
    searchProvider: @escaping (String, AppSearchDomain?) async -> AppSearchResults
  ) {
    self.searchProvider = searchProvider
  }

  /// Run a search and apply its results, unless the surrounding `Task`
  /// is cancelled while the actor is computing.
  ///
  /// Empty / whitespace-only input short-circuits to ``AppSearchResults/empty``
  /// without crossing the actor boundary.
  @discardableResult
  public func runSearch(
    query rawQuery: String,
    primary: AppSearchDomain?
  ) async -> AppSearchResults {
    let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      applySearchState(query: "", results: .empty, isSearching: false)
      return .empty
    }
    setSearching(true)
    let next = await searchProvider(trimmed, primary)
    guard !Task.isCancelled else {
      setSearching(false)
      return results
    }
    applySearchState(query: trimmed, results: next, isSearching: false)
    return next
  }

  /// Reset query, results, and the in-flight flag. Call when the user
  /// dismisses the search field.
  public func clear() {
    applySearchState(query: "", results: .empty, isSearching: false)
  }

  public func setPresented(_ isPresented: Bool) {
    guard self.isPresented != isPresented else { return }
    self.isPresented = isPresented
  }

  private func applySearchState(
    query: String,
    results: AppSearchResults,
    isSearching: Bool
  ) {
    if self.query != query {
      self.query = query
    }
    if self.results != results {
      self.results = results
    }
    setSearching(isSearching)
  }

  private func setSearching(_ isSearching: Bool) {
    if self.isSearching != isSearching {
      self.isSearching = isSearching
    }
  }
}
