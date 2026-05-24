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
    #expect(indexSource.contains("index = nil\n    indexesByDomain = [:]"))
    #expect(indexSource.contains("let nextIndex = Self.makeIndex(records: records)"))
    #expect(
      !indexSource.contains(
        "let nextIndex = Self.makeIndex(records: records)\n    let nextRecordsByDomain"
      )
    )
  }

  private func harnessKitSourceFile(named relativePath: String) throws -> String {
    try String(contentsOf: harnessKitSourceURL(named: relativePath), encoding: .utf8)
  }

  private func harnessKitSourceURL(named relativePath: String) -> URL {
    repoRoot()
      .appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitorKit")
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
