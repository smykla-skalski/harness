import Foundation
import Observation
import os

@MainActor
@Observable
public final class OpenAnythingPaletteModel {
  public enum DismissReason: Sendable, Hashable {
    case userCanceled
    case hitExecuted(recordID: String)
    case windowResignedKey
    case scenePhaseBackground
  }

  public var query = "" {
    didSet {
      guard oldValue != query else { return }
      // Sticky selection: keep the currently selected hit if it survives the
      // new query's result set. `normalizeSelection` runs after `runSearch`
      // updates `results`; reset only if the selection becomes invalid.
    }
  }

  public private(set) var isPresented = false
  public private(set) var targetWindowID: String?
  public private(set) var scope: OpenAnythingDomain?
  public private(set) var results = OpenAnythingResults.empty
  public private(set) var suggestedResults = OpenAnythingResults.empty
  public private(set) var selectedHitID: String?
  public private(set) var lastDismissReason: DismissReason?
  /// Synchronous mirror of `index.recordCount()`, updated whenever
  /// `replaceCorpus` accepts a new corpus. Lets read-only callers (Commands,
  /// debug badges) observe corpus size without dropping into the actor.
  public private(set) var recordCount: Int = 0
  /// Last user-submitted query so present(restoreLastQuery: true) can offer
  /// it back to the user. Set when the user executes a hit; cleared on
  /// explicit clear via the field's xmark button.
  public private(set) var lastSubmittedQuery: String = ""
  /// Audit #89: per-section cap surfaced through Settings so a user with a
  /// large corpus can choose to see more matches per domain at the cost of
  /// scroll length. Defaults match the index's own defaults so unchanged
  /// callers behave identically.
  public var limitPerDomain: Int = OpenAnythingPreferencesDefaults.perDomainLimitDefault

  @ObservationIgnored private let index: OpenAnythingIndex
  @ObservationIgnored public let recency: OpenAnythingRecencyStore
  @ObservationIgnored public let pins: OpenAnythingPinStore
  @ObservationIgnored private var pendingSearchTask: Task<Void, Never>?

  public init(
    index: OpenAnythingIndex = OpenAnythingIndex(),
    recency: OpenAnythingRecencyStore = OpenAnythingRecencyStore(),
    pins: OpenAnythingPinStore = OpenAnythingPinStore()
  ) {
    self.index = index
    self.recency = recency
    self.pins = pins
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

  public func present(
    targetWindowID: String?,
    scope: OpenAnythingDomain? = nil,
    restoreLastQuery: Bool = false
  ) {
    let signpost = OpenAnythingSignposter.shared.beginInterval(
      OpenAnythingSignposter.Interval.present
    )
    defer { OpenAnythingSignposter.shared.endInterval(
      OpenAnythingSignposter.Interval.present,
      signpost
    ) }
    self.targetWindowID = targetWindowID
    let scopeChanged = self.scope != scope
    self.scope = scope
    // Audit #95: when the Settings toggle is on, the model offers up the
    // last query the user submitted so reopening the palette resumes where
    // they were. The default is off so opening the palette stays a clean
    // surface for most users.
    query = restoreLastQuery ? lastSubmittedQuery : ""
    results = .empty
    selectedHitID = nil
    isPresented = true
    lastDismissReason = nil
    // When the caller swaps scope (or sets one for the first time after a
    // previous unscoped session), the cached `suggestedResults` was filtered
    // against the prior scope. Re-fetch from the index and re-filter so the
    // empty-query lane reflects the current scope immediately.
    if scopeChanged {
      Task { await refreshSuggestedResults() }
    }
  }

  /// Mark the palette dismissed and record why. Idempotent: a second call
  /// with the palette already dismissed is a no-op rather than overwriting
  /// `lastDismissReason`. Pass the reason so downstream telemetry / tests can
  /// tell user-canceled (Escape, scrim tap) from window-resign or scene-phase
  /// auto-dismiss.
  public func dismiss(reason: DismissReason = .userCanceled) {
    guard isPresented else { return }
    pendingSearchTask?.cancel()
    pendingSearchTask = nil
    query = ""
    results = .empty
    selectedHitID = nil
    targetWindowID = nil
    scope = nil
    isPresented = false
    lastDismissReason = reason
  }

  public func isPresented(in windowID: String, isKeyWindow: Bool) -> Bool {
    guard isPresented else { return false }
    guard let targetWindowID else { return isKeyWindow }
    return targetWindowID == windowID
  }

  public func replaceCorpus(_ records: [OpenAnythingRecord]) async {
    let signpost = OpenAnythingSignposter.shared.beginInterval(
      OpenAnythingSignposter.Interval.corpusRebuild
    )
    await index.replace(records: records)
    suggestedResults = applyRanking(
      to: Self.filtered(
        await index.suggestedResults(limitPerDomain: limitPerDomain),
        by: scope
      ),
      records: records
    )
    recordCount = records.count
    OpenAnythingSignposter.shared.endInterval(
      OpenAnythingSignposter.Interval.corpusRebuild,
      signpost
    )
    guard isPresented, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      normalizeSelection()
      return
    }
    await runSearch()
  }

  public func runSearch() async {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      // Empty queries display the suggested lane; skip the actor hop entirely.
      results = .empty
      normalizeSelection()
      return
    }
    let signpost = OpenAnythingSignposter.shared.beginInterval(
      OpenAnythingSignposter.Interval.search
    )
    let snapshot = await index.search(query: trimmed, limitPerDomain: limitPerDomain)
    OpenAnythingSignposter.shared.endInterval(
      OpenAnythingSignposter.Interval.search,
      signpost
    )
    guard !Task.isCancelled else { return }
    results = applyRanking(to: Self.filtered(snapshot, by: scope), records: nil)
    normalizeSelection()
  }

  /// Schedule a search for the current query. Cancels any in-flight search
  /// first. Use this from the view's `.task(id: query)` instead of calling
  /// `runSearch()` directly so the previous keystroke's task cannot land
  /// stale results on top of the new keystroke's results.
  public func scheduleSearch() {
    pendingSearchTask?.cancel()
    pendingSearchTask = Task { [weak self] in
      await self?.runSearch()
    }
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

  /// Set the selection to a specific hit id, but only if that id appears in
  /// the currently displayed results. No-op otherwise so callers (hover,
  /// section-jump shortcuts) cannot leak a stale id past a corpus refresh.
  public func selectHit(id: String) {
    guard displayedResults.allHits.contains(where: { $0.id == id }) else { return }
    selectedHitID = id
  }

  /// Record that the user just executed a record so the recency store can
  /// promote it next time the palette is opened. Call from the palette view
  /// when the user picks a hit.
  public func recordExecution(of recordID: String) {
    recency.record(recordID)
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
      lastSubmittedQuery = trimmed
    }
    lastDismissReason = .hitExecuted(recordID: recordID)
  }

  /// Toggle the pinned status of `recordID`. Returns the new pinned state.
  @discardableResult
  public func togglePin(_ recordID: String) -> Bool {
    if pins.isPinned(recordID) {
      pins.unpin(recordID)
      return false
    } else {
      pins.pin(recordID)
      return true
    }
  }

  private func refreshSuggestedResults() async {
    let raw = Self.filtered(
      await index.suggestedResults(limitPerDomain: limitPerDomain),
      by: scope
    )
    suggestedResults = applyRanking(to: raw, records: nil)
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

  /// Re-rank a results bundle so pinned items appear at the very top and
  /// recently-used items boost within their domain. Pinned records are
  /// gathered into a synthetic "actions" pseudo-section that floats above
  /// the natural domain order; recency boosts apply within each domain so
  /// the domain layout stays intuitive.
  private func applyRanking(
    to bundle: OpenAnythingResults,
    records: [OpenAnythingRecord]?
  ) -> OpenAnythingResults {
    let pinned = pins.recordIDs
    let now = Date()

    let rankedSections = bundle.sections.map { section -> OpenAnythingSection in
      let sortedHits = section.hits.sorted { lhs, rhs in
        let lhsScore = recency.score(for: lhs.id, now: now)
        let rhsScore = recency.score(for: rhs.id, now: now)
        if lhsScore != rhsScore { return lhsScore > rhsScore }
        return lhs.score < rhs.score
      }
      return OpenAnythingSection(domain: section.domain, hits: sortedHits)
    }

    guard !pinned.isEmpty else {
      return OpenAnythingResults(query: bundle.query, sections: rankedSections)
    }

    // Synthesize a pinned section by collecting any record in the bundle (or
    // the optional `records` fallback when the bundle is empty) that the user
    // has explicitly pinned. We project them into a synthetic .actions
    // section so the palette renders them under a labelled lane.
    let allHits = rankedSections.flatMap(\.hits)
    let candidates: [OpenAnythingHit]
    if let records, allHits.isEmpty {
      candidates = records.compactMap { record in
        guard pinned.contains(record.id) else { return nil }
        return OpenAnythingHit(record: record, highlights: .empty, score: 0)
      }
    } else {
      candidates = allHits.filter { pinned.contains($0.id) }
    }

    let pinnedHits = pinned.compactMap { id in
      candidates.first(where: { $0.id == id })
    }

    guard !pinnedHits.isEmpty else {
      return OpenAnythingResults(query: bundle.query, sections: rankedSections)
    }

    let pinnedSection = OpenAnythingSection(domain: .actions, hits: pinnedHits)
    let filteredRest = rankedSections.map { section in
      OpenAnythingSection(
        domain: section.domain,
        hits: section.hits.filter { !pinned.contains($0.id) }
      )
    }.filter { !$0.hits.isEmpty }

    return OpenAnythingResults(
      query: bundle.query,
      sections: [pinnedSection] + filteredRest
    )
  }
}
