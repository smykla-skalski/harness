import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
struct ReviewFilePreviewPrewarmTests {
  @Test("prewarm fetches visible paths before background paths")
  func prewarmVisiblePathsFirst() async throws {
    let client = RecordingHarnessClient()
    let (previewStore, directory) = makePreviewStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client),
      reviewFilePreviewStore: previewStore
    )
    store.client = client
    let viewModel = store.viewModel(forPullRequest: "pr-1")
    viewModel.ingest(response: response(paths: ["visible-a", "visible-b", "background-a"]))

    store.startPatchPreviewPrewarm(
      forPullRequest: "pr-1",
      visiblePaths: ["visible-a", "visible-b"],
      backgroundPaths: ["background-a"]
    )
    await store.reviewFilesPreviewWarmState.tasks["pr-1"]?.value

    let requests = client.recordedReviewPreviewRequests()
    #expect(requests.map(\.paths) == [["visible-a", "visible-b"], ["background-a"]])
  }

  @Test("new visible set cancels stale background prewarm")
  func prewarmCancellationDropsStaleBackground() async throws {
    let client = RecordingHarnessClient()
    client.configureReviewPreviewDelay(.milliseconds(500))
    let (previewStore, directory) = makePreviewStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client),
      reviewFilePreviewStore: previewStore
    )
    store.client = client
    let viewModel = store.viewModel(forPullRequest: "pr-1")
    viewModel.ingest(response: response(paths: ["old-visible", "old-background", "new-visible"]))

    store.startPatchPreviewPrewarm(
      forPullRequest: "pr-1",
      visiblePaths: ["old-visible"],
      backgroundPaths: ["old-background"]
    )
    #expect(await waitForPreviewRequestCount(1, client: client))

    client.configureReviewPreviewDelay(nil)
    store.startPatchPreviewPrewarm(
      forPullRequest: "pr-1",
      visiblePaths: ["new-visible"],
      backgroundPaths: []
    )
    await store.reviewFilesPreviewWarmState.tasks["pr-1"]?.value

    let requestedPathSets = client.recordedReviewPreviewRequests().map(\.paths)
    #expect(requestedPathSets.contains(["new-visible"]))
    #expect(!requestedPathSets.contains(["old-background"]))
  }

  private func waitForPreviewRequestCount(
    _ count: Int,
    client: RecordingHarnessClient
  ) async -> Bool {
    for _ in 0..<50 {
      if client.recordedReviewPreviewRequests().count >= count {
        return true
      }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
  }

  private func response(paths: [String]) -> ReviewsFilesListResponse {
    ReviewsFilesListResponse(
      pullRequestID: "pr-1",
      number: 1,
      headRefOid: "head-a",
      repositoryFullName: "owner/repo",
      viewerCanMarkViewed: true,
      files: paths.map { ReviewFile(path: $0, additions: 1, languageHint: .swift) },
      fetchedAt: "2026-05-23T12:00:00Z"
    )
  }

  private func makePreviewStore() -> (ReviewFilePreviewStore, URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("review-preview-prewarm-\(UUID().uuidString)", isDirectory: true)
    return (ReviewFilePreviewStore(directory: directory), directory)
  }
}
