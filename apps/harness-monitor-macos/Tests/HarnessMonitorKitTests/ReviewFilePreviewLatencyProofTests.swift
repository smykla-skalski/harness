import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
struct ReviewFilePreviewLatencyProofTests {
  private let visibleBatchSize = 24

  @Test("cache-hot preview access stays under 100ms across PR sizes", arguments: [10, 100, 400])
  func cacheHotPreviewAccessUnder100ms(fileCount: Int) async throws {
    let pullRequestID = "pr-\(fileCount)"
    let headRefOid = "head-\(fileCount)"
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("review-preview-latency-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let files = makeFiles(count: fileCount)
    let visiblePaths = Array(files.prefix(visibleBatchSize).map(\.path))
    let seedStore = ReviewFilePreviewStore(directory: directory, debounceNanoseconds: 1_000_000)
    for path in visiblePaths {
      await seedStore.store(
        pullRequestID: pullRequestID,
        headRefOid: headRefOid,
        preview: preview(path: path, headRefOid: headRefOid)
      )
    }
    await seedStore.flushPending()

    let reopenedStore = ReviewFilePreviewStore(directory: directory)
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      reviewFilePreviewStore: reopenedStore
    )
    let viewModel = store.viewModel(forPullRequest: pullRequestID)
    viewModel.ingest(
      response: ReviewsFilesListResponse(
        pullRequestID: pullRequestID,
        number: UInt64(fileCount),
        headRefOid: headRefOid,
        repositoryFullName: "owner/repo",
        viewerCanMarkViewed: true,
        files: files,
        fetchedAt: "2026-05-23T12:00:00Z"
      )
    )

    let started = DispatchTime.now().uptimeNanoseconds
    await store.preparePatchPreviews(
      forPullRequest: pullRequestID,
      paths: visiblePaths,
      lineLimit: ReviewFilePreview.defaultLineLimit
    )
    let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000

    #expect(elapsedMs < 100)
    for path in visiblePaths {
      guard case .loaded(let loaded) = viewModel.previews[path] else {
        Issue.record("Expected cached preview for \(path)")
        continue
      }
      #expect(loaded.patch.contains("+line 199"))
      #expect(loaded.lineLimit == ReviewFilePreview.defaultLineLimit)
    }
  }

  private func makeFiles(count: Int) -> [ReviewFile] {
    (0..<count).map { index in
      ReviewFile(
        path: String(format: "src/file-%03d.swift", index),
        additions: 200,
        deletions: 0,
        languageHint: .swift
      )
    }
  }

  private func preview(path: String, headRefOid: String) -> ReviewFilePreview {
    let lines = (0..<200).map { "+line \($0)" }.joined(separator: "\n")
    return ReviewFilePreview(
      path: path,
      patch: "@@ -0,0 +1,200 @@\n\(lines)\n",
      status: .modified,
      additions: 200,
      deletions: 0,
      servedBy: .githubRest,
      fetchedAt: "2026-05-23T12:00:00Z",
      headRefOid: headRefOid,
      lineCount: 200,
      lineLimit: ReviewFilePreview.defaultLineLimit,
      hasMore: false
    )
  }
}
