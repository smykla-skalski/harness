import Foundation
import Observation

@MainActor
@Observable
public final class OpenAnythingPaletteModel {
  public var query = "" {
    didSet {
      guard oldValue != query else { return }
      selectedHitID = nil
    }
  }

  public private(set) var isPresented = false
  public private(set) var targetWindowID: String?
  public private(set) var scope: OpenAnythingDomain?
  public private(set) var results = OpenAnythingResults.empty
  public private(set) var suggestedResults = OpenAnythingResults.empty
  public private(set) var selectedHitID: String?
  /// Synchronous mirror of `index.recordCount()`, updated whenever
  /// `replaceCorpus` accepts a new corpus. Lets read-only callers (Commands,
  /// debug badges) observe corpus size without dropping into the actor.
  public private(set) var recordCount: Int = 0

  @ObservationIgnored private let index: OpenAnythingIndex

  public init(index: OpenAnythingIndex = OpenAnythingIndex()) {
    self.index = index
  }

  public var selectedHit: OpenAnythingHit? {
    let hits = displayedResults.allHits
    guard !hits.isEmpty else { return nil }
    if let selectedHitID, let selected = hits.first(where: { $0.id == selectedHitID }) {
      return selected
    }
    return hits.first
  }

  public var displayedResults: OpenAnythingResults {
    query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? suggestedResults
      : results
  }

  public func present(targetWindowID: String?, scope: OpenAnythingDomain? = nil) {
    self.targetWindowID = targetWindowID
    let scopeChanged = self.scope != scope
    self.scope = scope
    query = ""
    results = .empty
    selectedHitID = nil
    isPresented = true
    // When the caller swaps scope (or sets one for the first time after a
    // previous unscoped session), the cached `suggestedResults` was filtered
    // against the prior scope. Re-fetch from the index and re-filter so the
    // empty-query lane reflects the current scope immediately.
    if scopeChanged {
      Task { await refreshSuggestedResults() }
    }
  }

  private func refreshSuggestedResults() async {
    suggestedResults = Self.filtered(await index.suggestedResults(), by: scope)
    normalizeSelection()
  }

  public func dismiss() {
    guard isPresented || !query.isEmpty || !results.isEmpty else {
      return
    }
    query = ""
    results = .empty
    selectedHitID = nil
    targetWindowID = nil
    scope = nil
    isPresented = false
  }

  public func isPresented(in windowID: String, isKeyWindow: Bool) -> Bool {
    guard isPresented else { return false }
    guard let targetWindowID else { return isKeyWindow }
    return targetWindowID == windowID
  }

  public func replaceCorpus(_ records: [OpenAnythingRecord]) async {
    await index.replace(records: records)
    suggestedResults = Self.filtered(await index.suggestedResults(), by: scope)
    recordCount = records.count
    guard isPresented, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      normalizeSelection()
      return
    }
    await runSearch()
  }

  public func runSearch() async {
    let results = await index.search(query: query)
    guard !Task.isCancelled else { return }
    self.results = Self.filtered(results, by: scope)
    normalizeSelection()
  }

  public func moveSelection(by delta: Int) {
    let hits = displayedResults.allHits
    guard !hits.isEmpty else {
      selectedHitID = nil
      return
    }
    let currentIndex =
      selectedHitID.flatMap { selectedID in
        hits.firstIndex { $0.id == selectedID }
      } ?? 0
    let nextIndex = min(max(currentIndex + delta, 0), hits.count - 1)
    selectedHitID = hits[nextIndex].id
  }

  public func selectFirstHitIfNeeded() {
    normalizeSelection()
  }

  private func normalizeSelection() {
    let hits = displayedResults.allHits
    guard !hits.isEmpty else {
      selectedHitID = nil
      return
    }
    if let selectedHitID, hits.contains(where: { $0.id == selectedHitID }) {
      return
    }
    selectedHitID = hits.first?.id
  }

  /// Filter a results bundle to one domain in the model layer. Keeping this
  /// here (instead of inside the actor index) lets scope toggle cheaply
  /// without rebuilding the index, and keeps the index single-purpose.
  private static func filtered(
    _ results: OpenAnythingResults,
    by scope: OpenAnythingDomain?
  ) -> OpenAnythingResults {
    guard let scope else { return results }
    let scopedSections = results.sections.filter { $0.domain == scope }
    return OpenAnythingResults(query: results.query, sections: scopedSections)
  }
}
