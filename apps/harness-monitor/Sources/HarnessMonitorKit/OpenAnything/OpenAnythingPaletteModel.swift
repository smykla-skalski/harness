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
      setQueryTermIsEmpty(OpenAnythingQueryParser.parse(query).term.isEmpty)
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
  public private(set) var queryTermIsEmpty = true
  /// The most recent query that `runSearch` actually completed for. Used by
  /// the view to tell "search has caught up - results.isEmpty really means
  /// no matches" from "search has not run yet - hold the empty state until
  /// the debounced search lands so we never flash 'No results'".
  public private(set) var lastSearchedQuery: String = ""
  /// Synchronous mirror of `index.recordCount()`, updated whenever
  /// `replaceCorpus` accepts a new corpus. Lets read-only callers (Commands,
  /// debug badges) observe corpus size without dropping into the actor.
  public private(set) var recordCount: Int = 0
  /// Last user-submitted query so present(restoreLastQuery: true) can offer
  /// it back to the user. Set when the user executes a hit; cleared on
  /// explicit clear via the field's xmark button.
  public private(set) var lastSubmittedQuery: String = ""
  /// Per-section cap surfaced through Settings so a user with a large corpus
  /// can choose to see more matches per domain at the cost of scroll length.
  /// Defaults match the index's own defaults so unchanged callers behave
  /// identically.
  public var limitPerDomain: Int = OpenAnythingPreferencesDefaults.perDomainLimitDefault
  public var showsPinned: Bool = OpenAnythingPreferencesDefaults.showPinnedDefault
  public var showsRecent: Bool = OpenAnythingPreferencesDefaults.showRecentDefault
  public var keepsPaletteOpenOnCommandClick: Bool =
    OpenAnythingPreferencesDefaults.cmdClickBackgroundDefault
  /// Domains the user has chosen to expand past the per-section cap by tapping
  /// "Show all" on a section header. The set resets on dismiss so a fresh
  /// palette session starts compact again.
  public private(set) var expandedDomains: Set<OpenAnythingDomain> = []
  /// Sections the user has collapsed so the section header is visible but the
  /// hits hide. Keyed by section identity so synthetic sections like Pinned do
  /// not collapse their backing domain.
  public private(set) var collapsedSections: Set<String> = []
  /// Resolved query scope derived from a leading `@domain` prefix. Separate
  /// from `scope` (caller-supplied) so a query-time scope can layer on top of a
  /// presenter scope.
  public private(set) var queryScope: OpenAnythingDomain?

  @ObservationIgnored private let index: OpenAnythingIndex
  @ObservationIgnored public let recency: OpenAnythingRecencyStore
  @ObservationIgnored public let pins: OpenAnythingPinStore
  @ObservationIgnored private var pendingSearchTask: Task<Void, Never>?
  @ObservationIgnored private var corpusCache = OpenAnythingPaletteCorpusCache.empty
  @ObservationIgnored private var corpusReplacementGeneration = 0

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
    let currentResults = selectableResults
    guard !currentResults.isEmpty else { return nil }
    if let selectedHitID, let selected = currentResults.hit(id: selectedHitID) {
      return selected
    }
    return currentResults.firstHit
  }

  public var displayedResults: OpenAnythingResults {
    queryTermIsEmpty ? suggestedResults : results
  }

  public func present(
    targetWindowID: String?,
    scope: OpenAnythingDomain? = nil,
    restoreLastQuery: Bool = false
  ) {
    self.targetWindowID = targetWindowID
    self.scope = scope
    setQueryScope(nil)
    expandedDomains = []
    collapsedSections = []
    // When the Settings toggle is on, the model offers up the last query the
    // user submitted so reopening the palette resumes where they were. The
    // default is off so opening the palette stays a clean surface for most
    // users.
    query = restoreLastQuery ? lastSubmittedQuery : ""
    results = .empty
    lastSearchedQuery = ""
    setSelectedHitID(nil)
    isPresented = true
    lastDismissReason = nil
    // Recompute every time the palette opens so Settings changes such as
    // pinned visibility, recency ranking, and per-section caps are visible
    // before the user types.
    refreshSuggestedResults()
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
    lastSearchedQuery = ""
    setSelectedHitID(nil)
    targetWindowID = nil
    scope = nil
    setQueryScope(nil)
    expandedDomains = []
    collapsedSections = []
    isPresented = false
    lastDismissReason = reason
  }

  /// Flip the per-section expand flag and re-run the active search so the
  /// section grows to its full match list or shrinks back.
  public func toggleExpanded(_ domain: OpenAnythingDomain) {
    if expandedDomains.contains(domain) {
      expandedDomains.remove(domain)
    } else {
      expandedDomains.insert(domain)
    }
    let parsed = OpenAnythingQueryParser.parse(query)
    setQueryScope(parsed.scope)
    guard !parsed.term.isEmpty else {
      results = .empty
      lastSearchedQuery = query
      refreshSuggestedResults()
      return
    }
    refreshSuggestedResults()
    scheduleSearch()
  }

  /// Hide the hits under a section header. Collapsing a domain also clears any
  /// pending expansion on the same domain so the two affordances stay mutually
  /// exclusive.
  public func toggleCollapsed(sectionID: String, domain: OpenAnythingDomain) {
    if collapsedSections.contains(sectionID) {
      collapsedSections.remove(sectionID)
    } else {
      collapsedSections.insert(sectionID)
      if sectionID == domain.rawValue {
        expandedDomains.remove(domain)
      }
    }
    normalizeSelection()
  }

  public func isExpanded(_ domain: OpenAnythingDomain) -> Bool {
    expandedDomains.contains(domain)
  }

  public func isCollapsed(sectionID: String) -> Bool {
    collapsedSections.contains(sectionID)
  }

  public func isPresented(in windowID: String, isKeyWindow: Bool) -> Bool {
    guard isPresented else { return false }
    guard let targetWindowID else { return isKeyWindow }
    return targetWindowID == windowID
  }

  @discardableResult
  public func replaceCorpus(_ records: [OpenAnythingRecord]) async -> Bool {
    corpusReplacementGeneration += 1
    let generation = corpusReplacementGeneration
    let signpost = OpenAnythingSignposter.shared.beginInterval(
      OpenAnythingSignposter.Interval.corpusRebuild
    )
    defer {
      OpenAnythingSignposter.shared.endInterval(
        OpenAnythingSignposter.Interval.corpusRebuild,
        signpost
      )
    }
    guard !Task.isCancelled, generation == corpusReplacementGeneration else { return false }
    let indexReplaced = await index.replace(records: records)
    guard indexReplaced, !Task.isCancelled, generation == corpusReplacementGeneration else {
      return false
    }
    corpusCache = OpenAnythingPaletteCorpusCache(records: records)
    refreshSuggestedResults()
    recordCount = records.count
    guard isPresented, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      normalizeSelection()
      return true
    }
    await runSearch()
    return true
  }

  public func runSearch() async {
    let queryAtStart = query
    let parsed = OpenAnythingQueryParser.parse(queryAtStart)
    let oldQueryScope = queryScope
    setQueryScope(parsed.scope)
    let trimmed = parsed.term
    guard !trimmed.isEmpty else {
      // Empty queries display the suggested lane; skip the actor hop entirely.
      results = .empty
      lastSearchedQuery = queryAtStart
      if oldQueryScope != parsed.scope {
        refreshSuggestedResults()
      }
      normalizeSelection()
      return
    }
    let signpost = OpenAnythingSignposter.shared.beginInterval(
      OpenAnythingSignposter.Interval.search
    )
    let snapshot = await index.search(
      query: trimmed,
      limitPerDomain: limitPerDomain,
      unboundedDomains: expandedDomains,
      scope: effectiveScope
    )
    OpenAnythingSignposter.shared.endInterval(
      OpenAnythingSignposter.Interval.search,
      signpost
    )
    guard !Task.isCancelled else { return }
    guard query == queryAtStart else { return }
    results = applyRanking(to: snapshot, corpus: nil)
    lastSearchedQuery = queryAtStart
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
    let nextHitID = selectableResults.hitID(movingFrom: selectedHitID, by: delta)
    guard let nextHitID else {
      setSelectedHitID(nil)
      return
    }
    setSelectedHitID(nextHitID)
  }

  public func selectFirstHitIfNeeded() {
    normalizeSelection()
  }

  /// Set the selection to a specific hit id, but only if that id appears in
  /// the currently displayed results. No-op otherwise so callers (hover,
  /// section-jump shortcuts) cannot leak a stale id past a corpus refresh.
  public func selectHit(id: String) {
    guard selectedHitID != id else { return }
    guard selectableResults.containsHit(id: id) else { return }
    setSelectedHitID(id)
  }

  /// Record that the user just executed a record so the recency store can
  /// promote it next time the palette is opened. Call from the palette view
  /// when the user picks a hit.
  public func recordExecution(of recordID: String, refreshResults: Bool = false) {
    recency.record(recordID)
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
      lastSubmittedQuery = trimmed
    }
    lastDismissReason = .hitExecuted(recordID: recordID)
    if refreshResults {
      refreshResultsAfterRankingChange()
    }
  }

  /// Toggle the pinned status of `recordID`. Returns the new pinned state.
  @discardableResult
  public func togglePin(_ recordID: String) -> Bool {
    let changed: Bool
    if pins.isPinned(recordID) {
      changed = pins.unpin(recordID)
    } else {
      changed = pins.pin(recordID)
    }
    if changed {
      refreshResultsAfterRankingChange()
    }
    return pins.isPinned(recordID)
  }

  private func refreshResultsAfterRankingChange() {
    let parsed = OpenAnythingQueryParser.parse(query)
    setQueryScope(parsed.scope)
    refreshSuggestedResults()
    guard !parsed.term.isEmpty else {
      results = .empty
      lastSearchedQuery = query
      return
    }
    guard isPresented else { return }
    scheduleSearch()
  }

  private func refreshSuggestedResults() {
    let raw = Self.suggestedResults(
      from: corpusCache.suggestedRecords,
      limitPerDomain: limitPerDomain,
      unboundedDomains: expandedDomains,
      scope: effectiveScope
    )
    suggestedResults = applyRanking(to: raw, corpus: corpusCache)
    normalizeSelection()
  }

  private static func suggestedResults(
    from suggestedRecords: [OpenAnythingRecord],
    limitPerDomain: Int,
    unboundedDomains: Set<OpenAnythingDomain>,
    scope: OpenAnythingDomain?
  ) -> OpenAnythingResults {
    let visibleLimit = max(0, limitPerDomain)
    var totals: [OpenAnythingDomain: Int] = [:]
    var hitsByDomain: [OpenAnythingDomain: [OpenAnythingHit]] = [:]
    for record in suggestedRecords {
      let domain = record.domain
      if let scope, domain != scope { continue }
      totals[domain, default: 0] += 1
      let cap = unboundedDomains.contains(domain) ? Int.max : visibleLimit
      if (hitsByDomain[domain]?.count ?? 0) < cap {
        hitsByDomain[domain, default: []].append(
          OpenAnythingHit(record: record, highlights: .empty, score: 0)
        )
      }
    }
    let sectionDomains = scope.map { [$0] } ?? OpenAnythingDomain.displayOrder
    let sections = sectionDomains.compactMap { domain -> OpenAnythingSection? in
      guard totals[domain] != nil else {
        return nil
      }
      return OpenAnythingSection(domain: domain, hits: hitsByDomain[domain] ?? [])
    }
    return OpenAnythingResults(query: "", sections: sections, domainTotals: totals)
  }

  /// Resolved scope used by both search paths: a query-time `@domain` prefix
  /// wins over the presenter-supplied scope so a user can pivot inside a
  /// session-scoped palette to look up a setting.
  public var effectiveScope: OpenAnythingDomain? {
    queryScope ?? scope
  }

  private var selectableResults: OpenAnythingResults {
    displayedResults.excludingHits(inCollapsedSections: collapsedSections)
  }

  private func normalizeSelection() {
    let currentResults = selectableResults
    guard !currentResults.isEmpty else {
      setSelectedHitID(nil)
      return
    }
    if let selectedHitID, currentResults.containsHit(id: selectedHitID) {
      return
    }
    setSelectedHitID(currentResults.firstHit?.id)
  }

  private func setSelectedHitID(_ nextHitID: String?) {
    guard selectedHitID != nextHitID else { return }
    selectedHitID = nextHitID
  }

  private func setQueryTermIsEmpty(_ isEmpty: Bool) {
    guard queryTermIsEmpty != isEmpty else { return }
    queryTermIsEmpty = isEmpty
  }

  private func setQueryScope(_ scope: OpenAnythingDomain?) {
    guard queryScope != scope else { return }
    queryScope = scope
  }
}
