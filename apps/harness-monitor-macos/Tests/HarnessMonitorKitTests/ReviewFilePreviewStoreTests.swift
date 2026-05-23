import Foundation
import Testing

@testable import HarnessMonitorKit

struct ReviewFilePreviewStoreTests {
  private func makeStore(
    diskCapBytes: Int = 25 * 1024 * 1024,
    debounceNanoseconds: UInt64 = 5_000_000
  ) -> (ReviewFilePreviewStore, URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("review-file-preview-\(UUID().uuidString)", isDirectory: true)
    let store = ReviewFilePreviewStore(
      directory: directory,
      diskCapBytes: diskCapBytes,
      debounceNanoseconds: debounceNanoseconds
    )
    return (store, directory)
  }

  private func preview(
    path: String = "src/a.swift",
    patch: String = "@@ -1 +1 @@\n-a\n+b\n",
    headRefOid: String = "head-a",
    lineLimit: UInt32 = 200
  ) -> ReviewFilePreview {
    ReviewFilePreview(
      path: path,
      patch: patch,
      status: .modified,
      additions: 1,
      deletions: 1,
      servedBy: .githubRest,
      fetchedAt: "2026-05-23T12:00:00Z",
      headRefOid: headRefOid,
      lineCount: UInt32(patch.split(separator: "\n").count),
      lineLimit: lineLimit,
      hasMore: false
    )
  }

  private func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  @Test("preview survives a new store instance after flush")
  func persistsAcrossStoreInstances() async throws {
    let (store, directory) = makeStore()
    defer { cleanup(directory) }
    await store.store(
      pullRequestID: "pr-1",
      headRefOid: "head-a",
      preview: preview(path: "src/a.swift")
    )
    await store.flushPending()

    let reopened = ReviewFilePreviewStore(directory: directory)
    let loaded = await reopened.read(
      pullRequestID: "pr-1",
      headRefOid: "head-a",
      path: "src/a.swift",
      lineLimit: 200
    )
    #expect(loaded?.patch.contains("+b") == true)
  }

  @Test("line limit and head oid are part of the cache key")
  func keySeparatesHeadAndLineLimit() async throws {
    let (store, directory) = makeStore()
    defer { cleanup(directory) }
    await store.store(
      pullRequestID: "pr-1",
      headRefOid: "head-a",
      preview: preview(path: "src/a.swift", lineLimit: 200)
    )
    await store.flushPending()

    let same = await store.read(
      pullRequestID: "pr-1",
      headRefOid: "head-a",
      path: "src/a.swift",
      lineLimit: 200
    )
    let differentHead = await store.read(
      pullRequestID: "pr-1",
      headRefOid: "head-b",
      path: "src/a.swift",
      lineLimit: 200
    )
    let differentLimit = await store.read(
      pullRequestID: "pr-1",
      headRefOid: "head-a",
      path: "src/a.swift",
      lineLimit: 100
    )
    #expect(same != nil)
    #expect(differentHead == nil)
    #expect(differentLimit == nil)
  }

  @Test("clear removes pending and persisted previews")
  func clearWipesMemoryAndDisk() async throws {
    let (store, directory) = makeStore()
    defer { cleanup(directory) }
    await store.store(
      pullRequestID: "pr-1",
      headRefOid: "head-a",
      preview: preview(path: "src/a.swift")
    )
    await store.flushPending()
    await store.store(
      pullRequestID: "pr-1",
      headRefOid: "head-a",
      preview: preview(path: "src/b.swift", patch: "pending")
    )

    await store.clear()

    let first = await store.read(
      pullRequestID: "pr-1",
      headRefOid: "head-a",
      path: "src/a.swift",
      lineLimit: 200
    )
    let second = await store.read(
      pullRequestID: "pr-1",
      headRefOid: "head-a",
      path: "src/b.swift",
      lineLimit: 200
    )
    #expect(first == nil)
    #expect(second == nil)
    #expect(await store.currentDiskBytes() == 0)
  }

  @Test("makeKey is stable and line-limit aware")
  func makeKeyStable() {
    let first = ReviewFilePreviewStore.makeKey(
      pullRequestID: "pr-1",
      headRefOid: "head-a",
      path: "src/a.swift",
      lineLimit: 200
    )
    let same = ReviewFilePreviewStore.makeKey(
      pullRequestID: "pr-1",
      headRefOid: "head-a",
      path: "src/a.swift",
      lineLimit: 200
    )
    let different = ReviewFilePreviewStore.makeKey(
      pullRequestID: "pr-1",
      headRefOid: "head-a",
      path: "src/a.swift",
      lineLimit: 100
    )
    #expect(first == same)
    #expect(first != different)
  }
}
