import Foundation
import Testing

@Suite("AppOpenAnything performance source contracts")
struct AppOpenAnythingPerformanceSourceContractTests {
  @Test("Open Anything corpus rebuild stays outside SwiftUI body")
  func openAnythingCorpusRebuildStaysOutsideSwiftUIBody() throws {
    let hostSource = try harnessSourceFile(named: "App/HarnessMonitorApp+OpenAnything.swift")
    let corpusTaskSource = try harnessSourceFile(named: "App/OpenAnythingCorpusTask.swift")
    let corpusDriverSource = try harnessSourceFile(
      named: "App/OpenAnythingCorpusUpdateDriver.swift"
    )
    let corpusSource = try harnessKitSourceFile(
      named: "OpenAnything/OpenAnythingCorpusBuilder.swift"
    )

    // The SwiftUI corpus host must not walk source collections from body.
    // Observation-driven rebuilds keep body evaluation cheap while still
    // tracking every source field read by the input builder.
    #expect(hostSource.contains("@State private var corpusDriver"))
    #expect(hostSource.contains("corpusDriver.start(coordinator: coordinator)"))
    #expect(!hostSource.contains("OpenAnythingCorpusSourceSignature.compute(input)"))
    #expect(!hostSource.contains(".task(id: sourceSignature)"))
    #expect(corpusDriverSource.contains("withObservationTracking"))
    #expect(corpusDriverSource.contains("Task.detached(priority: .utility)"))
    #expect(
      corpusDriverSource.contains(
        "OpenAnythingCorpusTask.sourceSignature(input: input)"
      )
    )
    #expect(corpusDriverSource.contains("coordinator.lastSignature == sourceSignature"))
    #expect(corpusDriverSource.contains("OpenAnythingCorpusTask.records(input: input)"))
    #expect(corpusTaskSource.contains("OpenAnythingCorpusSourceSignature.compute(input)"))
    #expect(corpusDriverSource.contains("OpenAnythingCorpusTask.signature("))
    #expect(!corpusTaskSource.contains("withTaskGroup"))
    #expect(!corpusTaskSource.contains("group.addTask(priority: .utility)"))
    #expect(corpusTaskSource.contains("OpenAnythingCorpusBuilder.records(input: input)"))
    #expect(corpusTaskSource.contains("OpenAnythingCorpusSignature.compute(records)"))
    #expect(corpusDriverSource.contains("guard !Task.isCancelled else { return }"))
    #expect(corpusSource.contains("guard !Task.isCancelled else { return [] }"))
    #expect(!hostSource.contains("let records = makeRecords()"))
  }

  @Test("Open Anything performance hot paths stay debounced and scoped")
  func openAnythingPerformanceContracts() throws {
    let hostSource = try harnessSourceFile(named: "App/HarnessMonitorApp+OpenAnything.swift")
    let paletteSource = try previewableSourceFile(named: "Views/App/OpenAnythingPaletteView.swift")
    let footerSource = try previewableSourceFile(named: "Views/App/OpenAnythingPaletteFooter.swift")
    let modelSource = try harnessKitSourceFile(
      named: "OpenAnything/OpenAnythingPaletteModel.swift"
    )
    let rankingSource = try harnessKitSourceFile(
      named: "OpenAnything/OpenAnythingPaletteModel+Ranking.swift"
    )
    let indexSource = try harnessKitSourceFile(named: "OpenAnything/OpenAnythingIndex.swift")
    let traversalSource = try harnessKitSourceFile(
      named: "OpenAnything/OpenAnythingResults+Traversal.swift"
    )
    let corpusSource = try harnessKitSourceFile(
      named: "OpenAnything/OpenAnythingCorpusBuilder.swift"
    )
    let loadedSessionCorpusSource = try harnessKitSourceFile(
      named: "OpenAnything/OpenAnythingCorpusBuilder+LoadedSession.swift"
    )

    #expect(corpusSource.contains("guard !Task.isCancelled else { return [] }"))
    // Execution signposts wrap the full route loop.
    #expect(hostSource.contains("OpenAnythingSignposter.Interval.execute"))
    #expect(modelSource.contains("guard query == queryAtStart else { return }"))
    #expect(modelSource.contains("corpusReplacementGeneration += 1"))
    #expect(modelSource.contains("generation == corpusReplacementGeneration"))

    // Per-keystroke search is debounced through the shared constant, while
    // empty/scope-only queries still run immediately.
    #expect(
      paletteSource.contains(
        "Task.sleep(\n        nanoseconds: OpenAnythingPaletteConstants.searchDebounceNanoseconds"
      )
    )
    #expect(paletteSource.contains("guard model.isPresented else { return }"))
    #expect(paletteSource.contains("if !model.queryTermIsEmpty"))
    #expect(!paletteSource.contains("OpenAnythingQueryParser.parse(model.query)"))

    // The panel is prewarmed and alpha-hidden, so local event monitors must
    // be tied to presentation state rather than one-time view appearance.
    #expect(paletteSource.contains(".onChange(of: model.isPresented)"))
    #expect(!paletteSource.contains(".onAppear { installWheelMonitor() }"))
    #expect(paletteSource.contains("removeWheelMonitor()"))
    #expect(paletteSource.contains("let stepCount = Int(abs(wheelAccumulator) / threshold)"))
    #expect(paletteSource.contains("model.moveSelection(by: direction * stepCount)"))
    #expect(!paletteSource.contains("while abs(wheelAccumulator) >= threshold"))
    #expect(paletteSource.contains("AccessibilityTextMarker("))
    #expect(!paletteSource.contains(".accessibilityElement(children: .contain)"))
    #expect(
      paletteSource.contains(
        "hasExactlyOneHit(excludingCollapsedSections: model.collapsedSections)")
    )
    #expect(!paletteSource.contains("visibleResults(in:"))
    #expect(paletteSource.contains("CharacterSet(charactersIn: \"12345678\")"))
    #expect(footerSource.contains("⌘1-8"))
    #expect(modelSource.contains("public private(set) var queryTermIsEmpty"))
    #expect(modelSource.contains("queryTermIsEmpty ? suggestedResults : results"))
    #expect(modelSource.contains("private func setSelectedHitID"))
    #expect(modelSource.contains("guard selectedHitID != nextHitID else { return }"))
    #expect(modelSource.contains("guard selectedHitID != id else { return }"))
    #expect(modelSource.contains("private func setQueryTermIsEmpty"))
    #expect(modelSource.contains("guard queryTermIsEmpty != isEmpty else { return }"))
    #expect(modelSource.contains("private func setQueryScope"))
    #expect(modelSource.contains("guard queryScope != scope else { return }"))
    #expect(modelSource.contains("if refreshResults && showsRecent {"))
    #expect(
      rankingSource.contains(
        "guard showsPinned || showsRecent || contextActive else { return bundle }"
      )
    )
    #expect(rankingSource.contains("guard showsRecent else { return bundle.sections }"))
    #expect(paletteSource.contains("if model.queryTermIsEmpty"))
    #expect(!paletteSource.contains("let queryEmpty = OpenAnythingQueryParser.parse(model.query)"))
    #expect(indexSource.contains("indexesByDomain"))
    #expect(indexSource.contains("searchIndex(scopedTo: scope)"))
    #expect(indexSource.contains("searchIndex.forEachCandidate(trimmed)"))
    #expect(!modelSource.contains("displayedResults.allHits"))
    #expect(!paletteSource.contains("allHits.count"))
    #expect(!indexSource.contains("for match in index.unsortedCandidates(trimmed)"))
    #expect(!traversalSource.contains("let total = hitCount"))
    #expect(!traversalSource.contains("selectedHitID.flatMap(indexOfHit)"))
    #expect(!traversalSource.contains("return hit(at: nextIndex)?.id"))
    #expect(!traversalSource.contains("private func indexOfHit"))
    #expect(!traversalSource.contains("private func hit(at flattenedIndex"))

    // The model should not also signpost present; the visible AppKit show
    // path owns that interval.
    #expect(!modelSource.contains("OpenAnythingSignposter.Interval.present"))
    #expect(
      loadedSessionCorpusSource.contains(
        "forEachMostRecentTimelineEntry(snapshot.timeline, limit: 200)"
      )
    )
    #expect(!loadedSessionCorpusSource.contains("snapshot.timeline.sorted"))
  }

  private func harnessSourceFile(named relativePath: String) throws -> String {
    try String(contentsOf: harnessSourceURL(named: relativePath), encoding: .utf8)
  }

  private func harnessKitSourceFile(named relativePath: String) throws -> String {
    try String(contentsOf: harnessKitSourceURL(named: relativePath), encoding: .utf8)
  }

  private func previewableSourceFile(named relativePath: String) throws -> String {
    try String(contentsOf: previewableSourceURL(named: relativePath), encoding: .utf8)
  }

  private func harnessSourceURL(named relativePath: String) -> URL {
    repoRoot()
      .appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitor")
      .appendingPathComponent(relativePath)
  }

  private func harnessKitSourceURL(named relativePath: String) -> URL {
    repoRoot()
      .appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitorKit")
      .appendingPathComponent(relativePath)
  }

  private func previewableSourceURL(named relativePath: String) -> URL {
    repoRoot()
      .appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitorUIPreviewable")
      .appendingPathComponent(relativePath)
  }

  private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
