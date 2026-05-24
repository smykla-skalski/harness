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
