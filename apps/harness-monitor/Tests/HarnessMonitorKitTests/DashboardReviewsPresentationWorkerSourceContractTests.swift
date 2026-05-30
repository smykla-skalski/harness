import Foundation
import Testing

@Suite("Dashboard reviews presentation worker source contracts")
struct DashboardReviewsWorkerSourceContractTests {
  @Test("presentation worker avoids transient filter and dictionary arrays")
  func presentationWorkerAvoidsTransientFilterAndDictionaryArrays() throws {
    let source = try workerSource()

    #expect(source.contains("filteredItems.reserveCapacity(items.count)"))
    #expect(source.contains("itemsByID(for: input.items)"))
    #expect(source.contains("result.reserveCapacity(items.count)"))
    #expect(!source.contains(".filter { categoryMode.matches($0) }"))
    #expect(!source.contains("Dictionary(grouping:"))
    #expect(!source.contains("Dictionary(\n        input.items.map"))
    #expect(!source.contains("items.map { item -> (String, String)"))
    #expect(source.contains("DashboardReviewsStatusGroupAccumulator"))
    #expect(!source.contains("minimumStatusBucket"))
    #expect(source.contains("DashboardReviewsPinnedPartition"))
    #expect(source.contains("orderedItems.reserveCapacity(items.count)"))
    #expect(!source.contains("return pinnedItems + unpinnedItems"))

    let repositoryGrouping = sourceSlice(
      source,
      from: "private static func repositoryGroupedItems",
      to: "private static func statusGroupedItems"
    )
    #expect(repositoryGrouping.contains("pinnedPartition.unpinnedItems"))
    #expect(!repositoryGrouping.contains("Set(pinnedPullRequestIDs)"))
    #expect(!repositoryGrouping.contains("var pinnedItems"))
  }

  @Test("presentation worker allocates date formatters only when labels are computed")
  func presentationWorkerLazilyAllocatesDateFormatters() throws {
    let source = try workerSource()

    #expect(source.contains("private var isoFormatterStorage: ISO8601DateFormatter?"))
    #expect(source.contains("private var relativeFormatterStorage: RelativeDateTimeFormatter?"))
    #expect(source.contains("guard !items.isEmpty else"))
    #expect(source.contains("let isoFormatter = isoFormatter"))
    #expect(!source.contains("private let isoFormatter = ISO8601DateFormatter()"))
    #expect(!source.contains("private let relativeFormatter"))
  }

  @Test("presentation worker caches relative date labels across recomputes")
  func presentationWorkerCachesRelativeDateLabelsAcrossRecomputes() throws {
    let source = try workerSource()

    #expect(source.contains("DashboardReviewsRelativeLabelCacheKey"))
    #expect(source.contains("private var relativeLabelCache:"))
    #expect(source.contains("let minuteBucket = Self.relativeLabelMinuteBucket(for: now)"))
    #expect(source.contains("if let cached = relativeLabelCache[key]"))
    #expect(source.contains("relativeLabelCache[key] = label"))
    #expect(source.contains("pruneRelativeLabelCacheIfNeeded()"))
    #expect(
      !source.contains(
        "if let date = isoFormatter.date(from: item.updatedAt) {"
      )
    )
  }

  private func workerSource() throws -> String {
    // File-length splits moved the grouping/partition helpers into the
    // +Grouping and Support companions. Union-read the worker base file with
    // them so every pinned literal (and the repository-grouping slice anchors)
    // resolves. The grouping companion stays a contiguous block, so the
    // repositoryGroupedItems -> statusGroupedItems slice still lands inside it.
    let base = try dashboardReviewsRouteSource(named: "DashboardReviewsPresentationWorker.swift")
    let grouping = try dashboardReviewsRouteSource(
      named: "DashboardReviewsPresentationWorker+Grouping.swift")
    let authorOrdering = try dashboardReviewsRouteSource(
      named: "DashboardReviewsPresentationWorker+AuthorOrdering.swift")
    let support = try dashboardReviewsRouteSource(
      named: "DashboardReviewsPresentationWorkerSupport.swift")
    return base + "\n" + grouping + "\n" + authorOrdering + "\n" + support
  }
}
