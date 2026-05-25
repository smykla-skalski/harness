import Foundation
import Testing

@testable import HarnessMonitorKit

extension ReviewFilesViewModelTests {
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
