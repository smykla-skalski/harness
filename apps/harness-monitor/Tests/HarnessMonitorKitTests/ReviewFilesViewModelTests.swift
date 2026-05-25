import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
struct ReviewFilesViewModelTests {
  @Test("files task key changes when the daemon comes online")
  func filesTaskKeyChangesWhenDaemonComesOnline() {
    let connecting = ReviewFilesTaskKey(pullRequestID: "pr-1", isDaemonOnline: false)
    let online = ReviewFilesTaskKey(pullRequestID: "pr-1", isDaemonOnline: true)

    #expect(connecting != online)
  }

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

  @Test("ingest(response:) builds stable file tree nodes once per file response")
  func ingestBuildsFileTreeNodes() {
    let vm = ReviewFilesViewModel(pullRequestID: "pr-1")
    vm.ingest(
      response: makeResponse(
        files: [
          makeFile(path: "Sources/App/main.swift"),
          makeFile(path: "Sources/App/Detail.swift"),
          makeFile(path: "README.md"),
        ]
      )
    )

    #expect(vm.fileTreeNodes.map(\.name) == ["Sources", "README.md"])
    #expect(vm.fileTreeNodes.first?.children.map(\.name) == ["App"])
    #expect(
      vm.fileTreeNodes.first?.children.first?.children.map(\.name) == [
        "main.swift",
        "Detail.swift",
      ])
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

  @Test("ingest(response:) selects the first unviewed file")
  func ingestSelectsFirstUnviewedFile() {
    let vm = ReviewFilesViewModel(pullRequestID: "pr-1")
    vm.ingest(
      response: makeResponse(
        files: [
          makeFile(path: "src/a.swift", viewed: .viewed),
          makeFile(path: "src/b.swift", viewed: .unviewed),
          makeFile(path: "src/c.swift", viewed: .unviewed),
        ]
      )
    )
    #expect(vm.selectedPath == "src/b.swift")
    #expect(vm.selectedFile?.path == "src/b.swift")
  }

  @Test("applyFilter preserves visible selection and moves hidden selection")
  func applyFilterMaintainsValidSelection() {
    let vm = ReviewFilesViewModel(pullRequestID: "pr-1")
    vm.ingest(
      response: makeResponse(
        files: [
          makeFile(path: "src/a.swift"),
          makeFile(path: "tests/b.swift"),
          makeFile(path: "docs/c.md"),
        ]
      )
    )
    vm.select(path: "tests/b.swift")
    vm.applyFilter(ReviewFilesFilter(searchText: "tests"))
    #expect(vm.selectedPath == "tests/b.swift")
    vm.applyFilter(ReviewFilesFilter(searchText: "docs"))
    #expect(vm.selectedPath == "docs/c.md")
  }

  @Test("selectNextUnviewed wraps from the selected file")
  func selectNextUnviewedWraps() {
    let vm = ReviewFilesViewModel(pullRequestID: "pr-1")
    vm.ingest(
      response: makeResponse(
        files: [
          makeFile(path: "src/a.swift", viewed: .unviewed),
          makeFile(path: "src/b.swift", viewed: .viewed),
          makeFile(path: "src/c.swift", viewed: .viewed),
        ]
      )
    )
    vm.select(path: "src/c.swift")
    vm.selectNextUnviewed()
    #expect(vm.selectedPath == "src/a.swift")
  }

  @Test("selectLines sets the line selection for the current file")
  func selectLinesSetsSelection() {
    let vm = ReviewFilesViewModel(pullRequestID: "pr-1")
    vm.ingest(response: makeResponse(files: [makeFile(path: "src/a.swift")]))
    vm.select(path: "src/a.swift")
    vm.selectLines(ReviewLineSelection(start: 10, end: 20, side: .right))
    #expect(vm.lineSelection == ReviewLineSelection(start: 10, end: 20, side: .right))
  }

  @Test("selecting a different file clears the line selection")
  func selectingDifferentFileClearsLineSelection() {
    let vm = ReviewFilesViewModel(pullRequestID: "pr-1")
    vm.ingest(
      response: makeResponse(
        files: [makeFile(path: "src/a.swift"), makeFile(path: "src/b.swift")]
      )
    )
    vm.select(path: "src/a.swift")
    vm.selectLines(ReviewLineSelection(line: 12))
    vm.select(path: "src/b.swift")
    #expect(vm.lineSelection == nil)
  }

  @Test("reselecting the same file keeps the line selection")
  func reselectingSameFileKeepsLineSelection() {
    let vm = ReviewFilesViewModel(pullRequestID: "pr-1")
    vm.ingest(response: makeResponse(files: [makeFile(path: "src/a.swift")]))
    vm.select(path: "src/a.swift")
    vm.selectLines(ReviewLineSelection(line: 7))
    vm.select(path: "src/a.swift")
    #expect(vm.lineSelection == ReviewLineSelection(line: 7))
  }

  @Test("clearing the selection clears the line selection")
  func clearingSelectionClearsLineSelection() {
    let vm = ReviewFilesViewModel(pullRequestID: "pr-1")
    vm.ingest(response: makeResponse(files: [makeFile(path: "src/a.swift")]))
    vm.select(path: "src/a.swift")
    vm.selectLines(ReviewLineSelection(line: 3))
    vm.select(path: nil)
    #expect(vm.lineSelection == nil)
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

  @Test("compiled generated matcher supports glob patterns at any depth")
  func compiledGeneratedMatcherSupportsGlobs() {
    let matcher = ReviewFilesGeneratedPathMatcher.compiled(
      from: [
        "package-lock.json",
        "**/vendor/**",
        "**/*.generated.swift",
      ]
    )

    #expect(matcher.matches("package-lock.json"))
    #expect(matcher.matches("ios/App/package-lock.json"))
    #expect(matcher.matches("Sources/vendor/module/file.swift"))
    #expect(matcher.matches("Sources/App/Feature.generated.swift"))
    #expect(!matcher.matches("Sources/App/Feature.swift"))
  }

  @Test("compiled generated matcher preserves legacy regex support")
  func compiledGeneratedMatcherPreservesLegacyRegexSupport() {
    let matcher = ReviewFilesGeneratedPathMatcher.compiled(
      from: [
        "(^|/)vendor/",
        "\\.generated\\.(swift|ts|js)$",
      ]
    )

    #expect(matcher.matches("nested/vendor/output.js"))
    #expect(matcher.matches("Sources/App/Feature.generated.swift"))
    #expect(!matcher.matches("Sources/App/Feature.swift"))
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

  @Test("viewed changes only rebuild filtered files for viewed-dependent sort modes")
  func viewedChangeRebuildsOnlyWhenSortDependsOnViewedState() {
    let vm = ReviewFilesViewModel(pullRequestID: "pr-1")
    vm.ingest(
      response: makeResponse(
        files: [
          makeFile(path: "src/a.swift"),
          makeFile(path: "src/b.swift"),
        ]
      )
    )

    let pathSortRevision = vm.filteredFilesRevision
    vm.setViewedState(path: "src/a.swift", state: .viewed)
    #expect(vm.filteredFilesRevision == pathSortRevision)

    vm.applySort(.unviewedFirst)
    let viewedSortRevision = vm.filteredFilesRevision
    vm.setViewedState(path: "src/b.swift", state: .viewed)
    #expect(vm.filteredFilesRevision > viewedSortRevision)
  }

  @Test("viewed revision advances only when effective viewed state changes")
  func viewedRevisionAdvancesOnlyWhenEffectiveStateChanges() {
    let vm = ReviewFilesViewModel(pullRequestID: "pr-1")
    vm.ingest(
      response: makeResponse(
        files: [
          makeFile(path: "src/a.swift"),
          makeFile(path: "src/b.swift"),
        ]
      )
    )

    let ingestRevision = vm.viewedStateRevision
    vm.setViewedState(path: "src/a.swift", state: .viewed)
    #expect(vm.viewedStateRevision == ingestRevision + 1)

    let viewedRevision = vm.viewedStateRevision
    vm.setViewedState(path: "src/a.swift", state: .viewed)
    #expect(vm.viewedStateRevision == viewedRevision)

    vm.markViewedBatch(paths: ["src/a.swift", "src/b.swift"], state: .viewed)
    #expect(vm.viewedStateRevision == viewedRevision + 1)
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

  @Test("ingest(previews:) stores first-line preview entries")
  func ingestPreviewStoresEntry() {
    let vm = ReviewFilesViewModel(pullRequestID: "pr-1")
    vm.ingest(
      previews: [
        ReviewFilePreview(
          path: "src/a.swift",
          patch: "@@ -1 +1 @@\n-a\n+b\n",
          lineCount: 3,
          lineLimit: 200,
          hasMore: false
        )
      ]
    )
    if case .loaded(let preview) = vm.previews["src/a.swift"] ?? .notLoaded {
      #expect(preview.lineCount == 3)
      #expect(!preview.hasMore)
    } else {
      Issue.record("Expected .loaded preview state")
    }
  }

  @Test("viewMode(forPath:) follows the global default for every file")
  func viewModeFollowsGlobalDefaultForEveryFile() {
    let vm = ReviewFilesViewModel(pullRequestID: "pr-1")
    vm.defaultViewMode = .split
    #expect(vm.viewMode(forPath: "any.swift") == .split)
    #expect(vm.viewMode(forPath: "other.swift") == .split)
    vm.defaultViewMode = .unified
    #expect(vm.viewMode(forPath: "any.swift") == .unified)
    #expect(vm.viewMode(forPath: "other.swift") == .unified)
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

  @Test("ingest(response:) drops previews whose paths no longer exist")
  func ingestEvictsStalePreviewsOnNewHead() {
    let vm = ReviewFilesViewModel(pullRequestID: "pr-1")
    vm.ingest(
      response: makeResponse(
        files: [makeFile(path: "old.swift"), makeFile(path: "shared.swift")],
        headRefOid: "head-a"
      )
    )
    vm.ingest(
      previews: [
        ReviewFilePreview(path: "old.swift", patch: "old", lineCount: 1),
        ReviewFilePreview(path: "shared.swift", patch: "shared", lineCount: 1),
      ]
    )
    vm.ingest(
      response: makeResponse(
        files: [makeFile(path: "shared.swift"), makeFile(path: "new.swift")],
        headRefOid: "head-b"
      )
    )
    #expect(vm.previews["old.swift"] == nil)
    #expect(vm.previews["shared.swift"] != nil)
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
