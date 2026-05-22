import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
struct ReviewFilesViewModelTests {
  private func makeFile(
    path: String,
    additions: UInt32 = 0,
    deletions: UInt32 = 0,
    viewed: ReviewFileViewedState = .unviewed
  ) -> ReviewFile {
    ReviewFile(
      path: path,
      changeType: .modified,
      additions: additions,
      deletions: deletions,
      viewerViewedState: viewed
    )
  }

  private func makeResponse(
    files: [ReviewFile],
    headRefOid: String = "head-a"
  ) -> ReviewsFilesListResponse {
    ReviewsFilesListResponse(
      pullRequestID: "pr-1",
      number: 42,
      headRefOid: headRefOid,
      headRefName: "renovate/foo",
      baseRefOid: "base-a",
      baseRefName: "main",
      repositoryFullName: "owner/repo",
      viewerCanMarkViewed: true,
      files: files,
      fetchedAt: "2026-05-22T12:00:00Z"
    )
  }

  @Test("ingest(response:) populates files, viewedByPath, and the load state")
  func ingestResponsePopulates() {
    let vm = ReviewFilesViewModel(pullRequestID: "pr-1")
    vm.ingest(
      response: makeResponse(
        files: [
          makeFile(path: "src/a.swift", additions: 5, deletions: 1, viewed: .viewed),
          makeFile(path: "src/b.swift", additions: 0, deletions: 0),
        ]
      )
    )
    #expect(vm.state == .loaded)
    #expect(vm.headRefOid == "head-a")
    #expect(vm.number == 42)
    #expect(vm.headRefName == "renovate/foo")
    #expect(vm.baseRefOid == "base-a")
    #expect(vm.baseRefName == "main")
    #expect(vm.repositoryFullName == "owner/repo")
    #expect(vm.files.map(\.path) == ["src/a.swift", "src/b.swift"])
    #expect(vm.viewedByPath["src/a.swift"] == .viewed)
    #expect(vm.viewedByPath["src/b.swift"] == .unviewed)
  }

  @Test("applyFilter restricts filteredFiles by searchText")
  func applyFilterSearchText() {
    let vm = ReviewFilesViewModel(pullRequestID: "pr-1")
    vm.ingest(
      response: makeResponse(
        files: [
          makeFile(path: "src/a.swift"),
          makeFile(path: "src/Tests/b.swift"),
          makeFile(path: "src/c.rs"),
        ]
      )
    )
    vm.applyFilter(ReviewFilesFilter(searchText: "Tests"))
    #expect(vm.filteredFiles.map(\.path) == ["src/Tests/b.swift"])
  }

  @Test("applyFilter with hideGenerated drops paths matched by the generated matcher")
  func applyFilterHideGenerated() {
    let matcher = ReviewFilesGeneratedPathMatcher(
      identifier: "lockfiles",
      match: { $0.hasSuffix("Package.resolved") }
    )
    let vm = ReviewFilesViewModel(pullRequestID: "pr-1")
    vm.ingest(
      response: makeResponse(
        files: [
          makeFile(path: "Package.resolved"),
          makeFile(path: "src/a.swift"),
        ]
      )
    )
    vm.applyFilter(
      ReviewFilesFilter(
        hideGenerated: true,
        generatedPathMatcher: matcher
      )
    )
    #expect(vm.filteredFiles.map(\.path) == ["src/a.swift"])
  }

  @Test("applyFilter with hideWhitespaceOnly drops zero-change files")
  func applyFilterWhitespaceOnly() {
    let vm = ReviewFilesViewModel(pullRequestID: "pr-1")
    vm.ingest(
      response: makeResponse(
        files: [
          makeFile(path: "src/a.swift", additions: 5, deletions: 0),
          makeFile(path: "src/whitespace.swift", additions: 0, deletions: 0),
        ]
      )
    )
    vm.applyFilter(ReviewFilesFilter(hideWhitespaceOnly: true))
    #expect(vm.filteredFiles.map(\.path) == ["src/a.swift"])
  }

  @Test("applySort(.lineChangesDescending) orders by total changes")
  func applySortByLineChanges() {
    let vm = ReviewFilesViewModel(pullRequestID: "pr-1")
    vm.ingest(
      response: makeResponse(
        files: [
          makeFile(path: "small.swift", additions: 1, deletions: 0),
          makeFile(path: "big.swift", additions: 100, deletions: 50),
          makeFile(path: "medium.swift", additions: 10, deletions: 10),
        ]
      )
    )
    vm.applySort(.lineChangesDescending)
    #expect(vm.sortedFiles.map(\.path) == ["big.swift", "medium.swift", "small.swift"])
  }

  @Test("markViewedBatch flips viewedByPath for all listed paths")
  func markViewedBatchFlipsAll() {
    let vm = ReviewFilesViewModel(pullRequestID: "pr-1")
    vm.ingest(
      response: makeResponse(
        files: [
          makeFile(path: "src/a.swift"),
          makeFile(path: "src/b.swift"),
          makeFile(path: "src/c.swift"),
        ]
      )
    )
    vm.markViewedBatch(paths: ["src/a.swift", "src/c.swift"], state: .viewed)
    #expect(vm.viewedByPath["src/a.swift"] == .viewed)
    #expect(vm.viewedByPath["src/b.swift"] == .unviewed)
    #expect(vm.viewedByPath["src/c.swift"] == .viewed)
  }

  @Test("setPatchState replaces the cached patch entry per path")
  func setPatchStateRoundTrip() {
    let vm = ReviewFilesViewModel(pullRequestID: "pr-1")
    vm.setPatchState(path: "src/a.swift", state: .loading)
    if case .loading = vm.patches["src/a.swift"] ?? .notLoaded {
      #expect(true)
    } else {
      Issue.record("Expected .loading patch state")
    }
  }

  @Test("viewMode(forPath:) falls back to defaultViewMode when no override is set")
  func viewModeFallsBackToDefault() {
    let vm = ReviewFilesViewModel(pullRequestID: "pr-1")
    vm.defaultViewMode = .split
    #expect(vm.viewMode(forPath: "any.swift") == .split)
    vm.setViewMode(.unified, forPath: "any.swift")
    #expect(vm.viewMode(forPath: "any.swift") == .unified)
    #expect(vm.viewMode(forPath: "other.swift") == .split)
  }

  @Test("ingest(response:) on a new headRefOid drops patches whose paths no longer exist")
  func ingestEvictsStalePatchesOnNewHead() {
    let vm = ReviewFilesViewModel(pullRequestID: "pr-1")
    vm.ingest(
      response: makeResponse(
        files: [makeFile(path: "old.swift"), makeFile(path: "shared.swift")],
        headRefOid: "head-a"
      )
    )
    vm.setPatchState(
      path: "old.swift",
      state: .loaded(
        ReviewFilePatch(
          path: "old.swift",
          patch: "diff",
          status: .modified,
          additions: 1,
          deletions: 1,
          truncated: false,
          servedBy: .githubRest
        )
      )
    )
    vm.setPatchState(
      path: "shared.swift",
      state: .loaded(
        ReviewFilePatch(
          path: "shared.swift",
          patch: "diff",
          status: .modified,
          additions: 1,
          deletions: 1,
          truncated: false,
          servedBy: .githubRest
        )
      )
    )
    vm.ingest(
      response: makeResponse(
        files: [makeFile(path: "shared.swift"), makeFile(path: "new.swift")],
        headRefOid: "head-b"
      )
    )
    #expect(vm.patches["old.swift"] == nil)
    #expect(vm.patches["shared.swift"] != nil)
  }

  @Test("toggleExpansion toggles membership in expandedPaths")
  func toggleExpansionFlipsMembership() {
    let vm = ReviewFilesViewModel(pullRequestID: "pr-1")
    vm.toggleExpansion(path: "src/a.swift")
    #expect(vm.expandedPaths.contains("src/a.swift"))
    vm.toggleExpansion(path: "src/a.swift")
    #expect(!vm.expandedPaths.contains("src/a.swift"))
  }
}
