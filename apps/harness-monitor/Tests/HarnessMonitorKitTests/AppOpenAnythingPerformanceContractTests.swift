import Foundation
import Testing

@Suite("AppOpenAnything performance contracts")
struct AppOpenAnythingPerformanceContractTests {
  @Test("Open Anything timeline corpus keeps ordered inputs on fast paths")
  func openAnythingTimelineCorpusFastPathContracts() throws {
    let timelineCorpusSource = try harnessKitSourceFile(
      named: "OpenAnything/OpenAnythingCorpusBuilder+Timeline.swift"
    )

    #expect(timelineCorpusSource.contains("if entriesAreMostRecentFirst(entries)"))
    #expect(timelineCorpusSource.contains("if entriesAreOldestFirst(entries)"))
    #expect(timelineCorpusSource.contains("guard entries.count > limit else"))
  }

  @Test("Open Anything offset traversal avoids shifting arrays")
  func openAnythingOffsetTraversalFastPathContracts() throws {
    let traversalSource = try harnessKitSourceFile(
      named: "OpenAnything/OpenAnythingResults+Traversal.swift"
    )

    #expect(traversalSource.contains("oldestPreviousIndex"))
    #expect(!traversalSource.contains("removeFirst()"))
  }

  @Test("Open Anything index replacement invalidates instead of rebuilding")
  func openAnythingIndexReplacementFastPathContracts() throws {
    let indexSource = try harnessKitSourceFile(named: "OpenAnything/OpenAnythingIndex.swift")

    #expect(indexSource.contains("private var index: FuzzySearchIndex<OpenAnythingRecord>?"))
    #expect(
      indexSource.contains(
        "private var recordsByDomain: [OpenAnythingDomain: [OpenAnythingRecord]]?"
      )
    )
    #expect(indexSource.contains("recordsByDomain = nil\n    index = nil"))
    #expect(indexSource.contains("groupedRecordsByDomain()[scope]"))
    #expect(indexSource.contains("let nextIndex = Self.makeIndex(records: records)"))
    #expect(
      !indexSource.contains(
        "let nextIndex = Self.makeIndex(records: records)\n    let nextRecordsByDomain"
      )
    )
  }

  @Test("Open Anything fuzzy prefix ranking avoids per-query field normalization")
  func openAnythingFuzzyPrefixRankingFastPathContracts() throws {
    let searchSource = try harnessKitSourceFile(named: "Search/FuzzySearchIndex.swift")
    let highlightSource = try harnessKitSourceFile(
      named: "Search/FuzzySearchIndex+Highlights.swift"
    )

    #expect(searchSource.contains("private let prefixValuesByIndex"))
    #expect(searchSource.contains("let highlightFields"))
    #expect(searchSource.contains("includeMatches: false"))
    #expect(highlightSource.contains("Fuse.match(query, in: value, options: highlightOptions)"))
    #expect(
      searchSource.contains(
        "prefixValuesByIndex = Self.makePrefixValues(items: items, prefixFields: prefixFields)"
      )
    )
    #expect(searchSource.contains("prefixRank(forRefIndex: result.refIndex"))
    #expect(!searchSource.contains("prefixRank(for: result.item"))
  }

  @Test("Open Anything display labels avoid split-map allocation")
  func openAnythingDisplayLabelFastPathContracts() throws {
    let corpusSource = try harnessKitSourceFile(
      named: "OpenAnything/OpenAnythingCorpusBuilder.swift"
    )
    let displayLabelSource = try sourceBlock(
      startingWith: "static func displayLabel(_ raw: String) -> String {",
      endingBefore: "\n  }\n}",
      in: corpusSource
    )

    #expect(displayLabelSource.contains("label.reserveCapacity(trimmed.count)"))
    #expect(!displayLabelSource.contains(".split(separator: \"_\""))
    #expect(!displayLabelSource.contains(".joined(separator: \" \")"))
  }

  @Test("Open Anything collapsed traversal avoids result filtering")
  func openAnythingCollapsedTraversalFastPathContracts() throws {
    let modelSource = try harnessKitSourceFile(
      named: "OpenAnything/OpenAnythingPaletteModel.swift"
    )
    let collapsedTraversalSource = try harnessKitSourceFile(
      named: "OpenAnything/OpenAnythingResults+CollapsedTraversal.swift"
    )

    #expect(
      collapsedTraversalSource.contains(
        "for section in sections where !collapsedSectionIDs.contains(section.id)"
      )
    )
    #expect(collapsedTraversalSource.contains("firstHitIDInVisibleSection("))
    #expect(!modelSource.contains("selectableResults"))
    #expect(!modelSource.contains("excludingHits(inCollapsedSections: collapsedSections)"))
  }

  @Test("Open Anything record search body avoids compact-map join allocation")
  func openAnythingRecordSearchBodyFastPathContracts() throws {
    let modelsSource = try harnessKitSourceFile(named: "OpenAnything/OpenAnythingModels.swift")
    let recordSource = try sourceBlock(
      startingWith: "public struct OpenAnythingRecord: Identifiable, Hashable, Sendable {",
      endingBefore: "\npublic struct OpenAnythingHit",
      in: modelsSource
    )

    #expect(recordSource.contains("searchBody = Self.joinSearchBody(searchBodyParts)"))
    #expect(recordSource.contains("private static func joinSearchBody"))
    #expect(!recordSource.contains(".compactMap(Self.nonEmpty).joined"))
  }

  @Test("Open Anything palette model reuses parsed query state")
  func openAnythingPaletteQueryParsingFastPathContracts() throws {
    let modelSource = try harnessKitSourceFile(
      named: "OpenAnything/OpenAnythingPaletteModel.swift"
    )

    #expect(modelSource.contains("@ObservationIgnored private var parsedQuery"))
    #expect(modelSource.contains("parsedQuery = parsed"))
    #expect(modelSource.contains("let parsed = parsedQuery"))
    #expect(!modelSource.contains("OpenAnythingQueryParser.parse(queryAtStart)"))
    #expect(modelSource.components(separatedBy: "OpenAnythingQueryParser.parse(").count == 2)
  }

  private func harnessKitSourceFile(named relativePath: String) throws -> String {
    try String(contentsOf: harnessKitSourceURL(named: relativePath), encoding: .utf8)
  }

  private func harnessKitSourceURL(named relativePath: String) -> URL {
    repoRoot()
      .appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitorKit")
      .appendingPathComponent(relativePath)
  }

  private func sourceBlock(
    startingWith startMarker: String,
    endingBefore endMarker: String,
    in source: String
  ) throws -> Substring {
    let start = try #require(source.range(of: startMarker)?.lowerBound)
    let suffix = source[start...]
    let end = try #require(suffix.range(of: endMarker)?.lowerBound)
    return suffix[..<end]
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
