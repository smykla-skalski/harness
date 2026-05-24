import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("OpenAnything palette model")
@MainActor
struct OpenAnythingPaletteModelTests {
  @Test("Present resets state and marks the model open")
  func presentResetsState() async {
    let model = Self.makeModel()
    model.present(targetWindowID: "win-1")

    #expect(model.isPresented)
    #expect(model.targetWindowID == "win-1")
    #expect(model.query.isEmpty)
    #expect(model.lastDismissReason == nil)
  }

  @Test("Dismiss is idempotent when not presented")
  func dismissIdempotent() async {
    let model = Self.makeModel()
    model.dismiss()
    #expect(model.isPresented == false)
    #expect(model.lastDismissReason == nil)
  }

  @Test("Dismiss records the reason")
  func dismissRecordsReason() async {
    let model = Self.makeModel()
    model.present(targetWindowID: nil)
    model.dismiss(reason: .windowResignedKey)

    #expect(model.isPresented == false)
    #expect(model.lastDismissReason == .windowResignedKey)
  }

  @Test("Empty query runSearch is a no-op actor hop")
  func emptyQueryRunSearchSkipsActor() async {
    let model = Self.makeModel()
    await model.replaceCorpus(Self.sampleRecords)
    model.present(targetWindowID: nil)
    model.query = "   "

    await model.runSearch()

    // The run did not populate `results`; displayedResults should still
    // surface the suggested-lane bundle.
    #expect(model.results == .empty)
  }

  @Test("Query caches whether the parsed term is empty")
  func queryCachesTermEmptiness() async {
    let model = Self.makeModel()

    model.query = "@sessions"
    #expect(model.queryTermIsEmpty)

    model.query = "@sessions alpha"
    #expect(model.queryTermIsEmpty == false)

    model.query = "@unknown"
    #expect(model.queryTermIsEmpty == false)
  }

  @Test("Selection navigation traverses sections without losing order")
  func selectionNavigationTraversesSections() async {
    let model = Self.makeModel()
    await model.replaceCorpus(Self.multiSectionSuggestedRecords)
    model.present(targetWindowID: nil)

    #expect(model.selectedHitID == "action.refresh")
    model.moveSelection(by: 1)
    #expect(model.selectedHitID == "window.dashboard")
    model.moveSelection(by: 1)
    #expect(model.selectedHitID == "session.alpha")
    model.moveSelection(by: -1)
    #expect(model.selectedHitID == "window.dashboard")
  }

  @Test("Selection navigation clamps at result bounds")
  func selectionNavigationClampsAtResultBounds() async {
    let model = Self.makeModel()
    await model.replaceCorpus(Self.multiSectionSuggestedRecords)
    model.present(targetWindowID: nil)

    model.moveSelection(by: -1)
    #expect(model.selectedHitID == "action.refresh")
    model.moveSelection(by: 10)
    #expect(model.selectedHitID == "session.alpha")
    model.moveSelection(by: 1)
    #expect(model.selectedHitID == "session.alpha")
    model.moveSelection(by: -10)
    #expect(model.selectedHitID == "action.refresh")
  }

  @Test("Offset selection traversal clamps across sections")
  func offsetSelectionTraversalClampsAcrossSections() {
    let results = Self.multiSectionSuggestedResults

    #expect(results.hitID(movingFrom: "action.refresh", by: 2) == "session.alpha")
    #expect(results.hitID(movingFrom: "session.alpha", by: -2) == "action.refresh")
    #expect(results.hitID(movingFrom: "missing", by: 2) == "session.alpha")
    #expect(results.hitID(movingFrom: "missing", by: -2) == "action.refresh")
    #expect(results.hitID(movingFrom: nil, by: 2) == "session.alpha")
  }

  @Test("Offset selection before current uses rolling buffer")
  func offsetSelectionBeforeCurrentUsesRollingBuffer() {
    let results = Self.denseSessionResults

    #expect(results.hitID(movingFrom: "session.6", by: -2) == "session.4")
    #expect(results.hitID(movingFrom: "session.6", by: -20) == "session.1")
  }

  @Test("Selection skips collapsed section hits")
  func selectionSkipsCollapsedSectionHits() async {
    let model = Self.makeModel()
    await model.replaceCorpus(Self.multiSectionSuggestedRecords)
    model.present(targetWindowID: nil)

    model.toggleCollapsed(sectionID: OpenAnythingDomain.actions.rawValue, domain: .actions)

    #expect(model.selectedHitID == "window.dashboard")
    #expect(model.selectedHit?.id == "window.dashboard")

    model.selectHit(id: "action.refresh")
    #expect(model.selectedHitID == "window.dashboard")

    model.moveSelection(by: 1)
    #expect(model.selectedHitID == "session.alpha")
  }

  @Test("Section jumps skip collapsed sections")
  func sectionJumpsSkipCollapsedSections() async {
    let model = Self.makeModel()
    await model.replaceCorpus(Self.multiSectionSuggestedRecords)
    model.present(targetWindowID: nil)
    model.toggleCollapsed(sectionID: OpenAnythingDomain.windows.rawValue, domain: .windows)
    let view = OpenAnythingPaletteView(model: model, execute: { _ in })

    #expect(model.selectedHitID == "action.refresh")
    view.jumpSection(by: 1)
    #expect(model.selectedHitID == "session.alpha")
    view.jumpSection(by: -1)
    #expect(model.selectedHitID == "action.refresh")
  }

  @Test("Digit section jumps skip collapsed sections")
  func digitSectionJumpsSkipCollapsedSections() async {
    let model = Self.makeModel()
    await model.replaceCorpus(Self.multiSectionSuggestedRecords)
    model.present(targetWindowID: nil)
    model.toggleCollapsed(sectionID: OpenAnythingDomain.windows.rawValue, domain: .windows)
    let view = OpenAnythingPaletteView(model: model, execute: { _ in })

    view.jumpToSection(index: 1)

    #expect(model.selectedHitID == "session.alpha")
  }

  @Test("Preview pane caps long match bodies")
  func previewPaneCapsLongMatchBodies() {
    let longBody = String(repeating: "x", count: 640)

    let preview = OpenAnythingPalettePreviewPane.previewSearchBody(longBody)

    #expect(preview?.count == 483)
    #expect(preview?.hasSuffix("...") == true)
  }

  @Test("Preview pane hides blank match bodies")
  func previewPaneHidesBlankMatchBodies() {
    #expect(OpenAnythingPalettePreviewPane.previewSearchBody("   \n\t") == nil)
  }

  @Test("Scope-only query displays scoped suggested results")
  func scopeOnlyQueryDisplaysSuggestedResults() async {
    let model = Self.makeModel()
    model.togglePin("session.alpha")
    await model.replaceCorpus(Self.sampleRecords)
    model.present(targetWindowID: nil)
    model.query = "@sessions"

    await model.runSearch()

    #expect(model.displayedResults.allHits.map(\.id) == ["session.alpha"])
  }

  @Test("Disabled ranking leaves suggested results in natural order")
  func disabledRankingLeavesSuggestedResultsInNaturalOrder() async {
    let model = Self.makeModel()
    model.showsPinned = false
    model.showsRecent = false
    model.togglePin("session.beta")
    model.recordExecution(of: "session.beta")
    await model.replaceCorpus(Self.suggestedSessionRecords)

    model.present(targetWindowID: nil)

    #expect(model.displayedResults.sections.map(\.id) == [OpenAnythingDomain.sessions.rawValue])
    #expect(model.displayedResults.allHits.map(\.id) == ["session.alpha", "session.beta"])
  }

  @Test("Expanding scoped suggestions avoids async search work")
  func expandingScopedSuggestionsAvoidsAsyncSearchWork() async {
    let model = Self.makeModel()
    model.limitPerDomain = 1
    await model.replaceCorpus(Self.multiSectionSuggestedRecords)
    model.present(targetWindowID: nil)
    model.query = "@sessions"

    model.toggleExpanded(.sessions)

    #expect(model.results == .empty)
    #expect(model.lastSearchedQuery == "@sessions")
    #expect(model.displayedResults.sections.map(\.domain) == [.sessions])
    #expect(model.displayedResults.allHits.map(\.id) == ["session.alpha"])
  }

  @Test("Selection survives a corpus refresh when the record remains")
  func stickySelectionAcrossCorpus() async {
    let model = Self.makeModel()
    await model.replaceCorpus(Self.sampleRecords)
    model.present(targetWindowID: nil)
    model.query = "alp"
    await model.runSearch()
    let initialSelection = model.selectedHitID
    #expect(initialSelection != nil)

    await model.replaceCorpus(Self.sampleRecords)
    #expect(model.selectedHitID == initialSelection)
  }

  @Test("Corpus cache separates suggested records from pinned lookup")
  func corpusCacheSeparatesSuggestedRecordsFromPinnedLookup() {
    let cache = OpenAnythingPaletteCorpusCache(records: Self.sampleRecords)

    #expect(cache.suggestedRecords.map(\.id) == ["action.refresh"])
    #expect(cache.record(id: "session.alpha")?.title == "Alpha Session")
  }

  @Test("Cancelled corpus replacement does not publish records")
  func cancelledCorpusReplacementDoesNotPublishRecords() async {
    let model = Self.makeModel()
    let task = Task { @MainActor in
      await model.replaceCorpus(Self.sampleRecords)
    }

    task.cancel()
    let accepted = await task.value

    #expect(accepted == false)
    #expect(model.recordCount == 0)
    #expect(model.suggestedResults == .empty)
  }

  @Test("Cancelled corpus replacement does not leak into search index")
  func cancelledCorpusReplacementDoesNotLeakIntoSearchIndex() async {
    let model = Self.makeModel()
    let task = Task { @MainActor in
      await model.replaceCorpus(Self.sampleRecords)
    }

    task.cancel()
    let accepted = await task.value

    #expect(accepted == false)
    model.present(targetWindowID: nil)
    model.query = "alpha"
    await model.runSearch()

    #expect(model.results.sections.isEmpty)
    #expect(model.displayedResults.allHits.isEmpty)
  }

  private static func makeModel() -> OpenAnythingPaletteModel {
    let suiteName = "OpenAnythingPaletteModelTests-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      preconditionFailure("Failed to create OpenAnythingPaletteModel test defaults")
    }
    return OpenAnythingPaletteModel(
      recency: OpenAnythingRecencyStore(defaults: defaults, key: "recency"),
      pins: OpenAnythingPinStore(defaults: defaults, key: "pins")
    )
  }

  private static let sampleRecords: [OpenAnythingRecord] = [
    OpenAnythingRecord(
      id: "action.refresh",
      domain: .actions,
      target: .action(.refresh),
      title: "Refresh",
      isSuggested: true
    ),
    OpenAnythingRecord(
      id: "session.alpha",
      domain: .sessions,
      target: .session(sessionID: "alpha"),
      title: "Alpha Session"
    ),
    OpenAnythingRecord(
      id: "session.beta",
      domain: .sessions,
      target: .session(sessionID: "beta"),
      title: "Beta Session"
    ),
  ]

  private static let multiSectionSuggestedRecords: [OpenAnythingRecord] = [
    OpenAnythingRecord(
      id: "action.refresh",
      domain: .actions,
      target: .action(.refresh),
      title: "Refresh",
      isSuggested: true
    ),
    OpenAnythingRecord(
      id: "window.dashboard",
      domain: .windows,
      target: .window(.dashboard),
      title: "Dashboard",
      isSuggested: true
    ),
    OpenAnythingRecord(
      id: "session.alpha",
      domain: .sessions,
      target: .session(sessionID: "alpha"),
      title: "Alpha Session",
      isSuggested: true
    ),
  ]

  private static var multiSectionSuggestedResults: OpenAnythingResults {
    OpenAnythingResults(
      query: "",
      sections: [
        OpenAnythingSection(
          domain: .actions,
          hits: [hit(for: multiSectionSuggestedRecords[0])]
        ),
        OpenAnythingSection(
          domain: .windows,
          hits: [hit(for: multiSectionSuggestedRecords[1])]
        ),
        OpenAnythingSection(
          domain: .sessions,
          hits: [hit(for: multiSectionSuggestedRecords[2])]
        ),
      ]
    )
  }

  private static var denseSessionResults: OpenAnythingResults {
    OpenAnythingResults(
      query: "",
      sections: [
        OpenAnythingSection(
          domain: .sessions,
          hits: (1...6).map { index in
            sessionHit(id: "\(index)")
          }
        )
      ]
    )
  }

  private static let suggestedSessionRecords: [OpenAnythingRecord] = [
    OpenAnythingRecord(
      id: "session.alpha",
      domain: .sessions,
      target: .session(sessionID: "alpha"),
      title: "Alpha Session",
      isSuggested: true
    ),
    OpenAnythingRecord(
      id: "session.beta",
      domain: .sessions,
      target: .session(sessionID: "beta"),
      title: "Beta Session",
      isSuggested: true
    ),
  ]

  private static func hit(for record: OpenAnythingRecord) -> OpenAnythingHit {
    OpenAnythingHit(record: record, highlights: .empty, score: 0)
  }

  private static func sessionHit(id: String) -> OpenAnythingHit {
    hit(
      for: OpenAnythingRecord(
        id: "session.\(id)",
        domain: .sessions,
        target: .session(sessionID: id),
        title: "Session \(id)"
      )
    )
  }
}
