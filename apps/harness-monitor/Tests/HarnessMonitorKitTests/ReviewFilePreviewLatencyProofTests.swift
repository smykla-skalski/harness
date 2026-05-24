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

  @Test("cache-hot full patch access skips daemon after app restart")
  func cacheHotPatchAccessSkipsDaemonAfterRestart() async throws {
    let pullRequestID = "pr-patch-cache"
    let headRefOid = "head-patch-cache"
    let path = "src/only-line-201.swift"
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("review-patch-latency-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let seedStore = ReviewFilePatchStore(directory: directory, debounceNanoseconds: 1_000_000)
    await seedStore.store(
      pullRequestID: pullRequestID,
      headRefOid: headRefOid,
      path: path,
      entry: ReviewFilePatchStore.Entry(
        patch: "@@ -200,0 +201,1 @@\n+cached tail\n",
        additions: 1,
        deletions: 0,
        fetchedAt: "2026-05-23T12:00:00Z"
      )
    )
    await seedStore.flushPending()

    let client = RecordingHarnessClient()
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client),
      reviewFilePatchStore: ReviewFilePatchStore(directory: directory)
    )
    store.client = client
    let viewModel = store.viewModel(forPullRequest: pullRequestID)
    viewModel.ingest(
      response: response(paths: [path], pullRequestID: pullRequestID, headRefOid: headRefOid)
    )

    let started = DispatchTime.now().uptimeNanoseconds
    await store.preparePatches(forPullRequest: pullRequestID, paths: [path])
    let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000

    #expect(elapsedMs < 100)
    #expect(client.recordedReviewPatchRequests().isEmpty)
    guard case .loaded(let patch) = viewModel.patches[path] else {
      Issue.record("Expected cached full patch")
      return
    }
    #expect(patch.patch.contains("cached tail"))
  }

  @Test("full patch response persists for the next app launch")
  func fullPatchResponsePersistsForNextLaunch() async throws {
    let pullRequestID = "pr-patch-persist"
    let headRefOid = "head-patch-persist"
    let path = "src/persisted.swift"
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("review-patch-persist-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let firstClient = RecordingHarnessClient()
    let firstStore = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: firstClient),
      reviewFilePatchStore: ReviewFilePatchStore(
        directory: directory,
        debounceNanoseconds: 1_000_000
      )
    )
    firstStore.client = firstClient
    let firstViewModel = firstStore.viewModel(forPullRequest: pullRequestID)
    firstViewModel.ingest(
      response: response(paths: [path], pullRequestID: pullRequestID, headRefOid: headRefOid)
    )

    await firstStore.preparePatches(forPullRequest: pullRequestID, paths: [path])
    await firstStore.reviewFilePatchStore.flushPending()
    #expect(firstClient.recordedReviewPatchRequests().map(\.paths) == [[path]])

    let secondClient = RecordingHarnessClient()
    let secondStore = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: secondClient),
      reviewFilePatchStore: ReviewFilePatchStore(directory: directory)
    )
    secondStore.client = secondClient
    let secondViewModel = secondStore.viewModel(forPullRequest: pullRequestID)
    secondViewModel.ingest(
      response: response(paths: [path], pullRequestID: pullRequestID, headRefOid: headRefOid)
    )

    await secondStore.preparePatches(forPullRequest: pullRequestID, paths: [path])

    #expect(secondClient.recordedReviewPatchRequests().isEmpty)
    guard case .loaded(let patch) = secondViewModel.patches[path] else {
      Issue.record("Expected persisted full patch")
      return
    }
    #expect(patch.patch.contains("+\(path)-full"))
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

  private func response(
    paths: [String],
    pullRequestID: String,
    headRefOid: String
  ) -> ReviewsFilesListResponse {
    ReviewsFilesListResponse(
      pullRequestID: pullRequestID,
      number: 1,
      headRefOid: headRefOid,
      repositoryFullName: "owner/repo",
      viewerCanMarkViewed: true,
      files: paths.map { ReviewFile(path: $0, additions: 1, languageHint: .swift) },
      fetchedAt: "2026-05-23T12:00:00Z"
    )
  }
}
