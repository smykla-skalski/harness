import Foundation
import Testing

@testable import HarnessMonitorKit

struct DependencyUpdateFilePatchStoreTests {
  private func makeStore(
    diskCapBytes: Int = 100 * 1024 * 1024,
    debounceNanoseconds: UInt64 = 5_000_000
  ) -> (DependencyUpdateFilePatchStore, URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("dep-files-patch-\(UUID().uuidString)", isDirectory: true)
    let store = DependencyUpdateFilePatchStore(
      directory: directory,
      diskCapBytes: diskCapBytes,
      debounceNanoseconds: debounceNanoseconds
    )
    return (store, directory)
  }

  private func entry(
    patch: String = "@@ -1 +1 @@\n-a\n+b\n",
    etag: String? = "W/\"abc\"",
    additions: UInt32 = 1,
    deletions: UInt32 = 1,
    truncated: Bool = false,
    status: DependencyUpdateFileChangeType = .modified,
    servedBy: DependencyUpdateFileServedBy = .githubRest,
    fetchedAt: String = "2026-05-22T12:00:00Z"
  ) -> DependencyUpdateFilePatchStore.Entry {
    DependencyUpdateFilePatchStore.Entry(
      patch: patch,
      etag: etag,
      additions: additions,
      deletions: deletions,
      truncated: truncated,
      status: status,
      servedBy: servedBy,
      fetchedAt: fetchedAt
    )
  }

  private func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  @Test("store then flushPending makes the entry readable")
  func storeFlushRead() async throws {
    let (store, dir) = makeStore()
    defer { cleanup(dir) }
    await store.store(
      pullRequestID: "pr-1",
      headRefOid: "head-a",
      path: "src/a.swift",
      entry: entry()
    )
    await store.flushPending()
    let loaded = await store.read(
      pullRequestID: "pr-1",
      headRefOid: "head-a",
      path: "src/a.swift"
    )
    #expect(loaded?.patch.contains("+b") == true)
    #expect(loaded?.etag == "W/\"abc\"")
  }

  @Test("read returns the pending entry before debounce flushes")
  func readSeesPendingBeforeFlush() async throws {
    let (store, dir) = makeStore(debounceNanoseconds: 5_000_000_000)
    defer { cleanup(dir) }
    await store.store(
      pullRequestID: "pr-1",
      headRefOid: "head-a",
      path: "src/a.swift",
      entry: entry(patch: "pre-flush")
    )
    let loaded = await store.read(
      pullRequestID: "pr-1",
      headRefOid: "head-a",
      path: "src/a.swift"
    )
    #expect(loaded?.patch == "pre-flush")
  }

  @Test("remove queues a delete that flushPending applies")
  func removeFlushDrops() async throws {
    let (store, dir) = makeStore()
    defer { cleanup(dir) }
    await store.store(
      pullRequestID: "pr-1",
      headRefOid: "head-a",
      path: "src/a.swift",
      entry: entry()
    )
    await store.flushPending()
    await store.remove(
      pullRequestID: "pr-1",
      headRefOid: "head-a",
      path: "src/a.swift"
    )
    await store.flushPending()
    let loaded = await store.read(
      pullRequestID: "pr-1",
      headRefOid: "head-a",
      path: "src/a.swift"
    )
    #expect(loaded == nil)
  }

  @Test("clear removes both memory pending writes and on-disk entries")
  func clearWipesEverything() async throws {
    let (store, dir) = makeStore()
    defer { cleanup(dir) }
    await store.store(
      pullRequestID: "pr-1",
      headRefOid: "head-a",
      path: "src/a.swift",
      entry: entry()
    )
    await store.flushPending()
    await store.store(
      pullRequestID: "pr-2",
      headRefOid: "head-b",
      path: "src/b.swift",
      entry: entry(patch: "pending")
    )
    await store.clear()
    let one = await store.read(
      pullRequestID: "pr-1",
      headRefOid: "head-a",
      path: "src/a.swift"
    )
    let two = await store.read(
      pullRequestID: "pr-2",
      headRefOid: "head-b",
      path: "src/b.swift"
    )
    #expect(one == nil)
    #expect(two == nil)
    #expect(await store.currentDiskBytes() == 0)
  }

  @Test("burst writes within debounce window flush as a single batch")
  func burstWritesCoalesce() async throws {
    let (store, dir) = makeStore(debounceNanoseconds: 50_000_000)
    defer { cleanup(dir) }
    for index in 0..<5 {
      await store.store(
        pullRequestID: "pr-1",
        headRefOid: "head-a",
        path: "src/file\(index).swift",
        entry: entry(patch: "patch-\(index)")
      )
    }
    await store.flushPending()
    var count = 0
    for index in 0..<5 {
      if let loaded = await store.read(
        pullRequestID: "pr-1",
        headRefOid: "head-a",
        path: "src/file\(index).swift"
      ) {
        #expect(loaded.patch == "patch-\(index)")
        count += 1
      }
    }
    #expect(count == 5)
  }

  @Test("LRU evicts the oldest entries when total bytes exceed the cap")
  func lruEvictsByMtime() async throws {
    // Each persisted entry serializes to roughly ~230 bytes. With a 600
    // byte cap, after the fifth write only the newest 2-3 entries fit so
    // the oldest are evicted before the test reads them.
    let bigPatch = String(repeating: "x", count: 64)
    let (store, dir) = makeStore(diskCapBytes: 600, debounceNanoseconds: 1_000_000)
    defer { cleanup(dir) }
    for index in 0..<5 {
      await store.store(
        pullRequestID: "pr-1",
        headRefOid: "head-a",
        path: "src/file\(index).swift",
        entry: entry(patch: "\(bigPatch)-\(index)")
      )
      await store.flushPending()
      // Each entry's mtime drifts by a microsecond on the same volume, so
      // sleep briefly to keep the LRU ordering reproducible.
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    let bytes = await store.currentDiskBytes()
    #expect(bytes <= 600)
    let newestPresent = await store.read(
      pullRequestID: "pr-1",
      headRefOid: "head-a",
      path: "src/file4.swift"
    )
    #expect(newestPresent != nil)
    let oldestPresent = await store.read(
      pullRequestID: "pr-1",
      headRefOid: "head-a",
      path: "src/file0.swift"
    )
    #expect(oldestPresent == nil)
  }

  @Test("currentDiskBytes reports the sum of on-disk patch entry sizes")
  func currentDiskBytesAccumulates() async throws {
    let (store, dir) = makeStore()
    defer { cleanup(dir) }
    await store.store(
      pullRequestID: "pr-1",
      headRefOid: "head-a",
      path: "src/a.swift",
      entry: entry()
    )
    await store.store(
      pullRequestID: "pr-1",
      headRefOid: "head-a",
      path: "src/b.swift",
      entry: entry()
    )
    await store.flushPending()
    let bytes = await store.currentDiskBytes()
    #expect(bytes > 0)
  }

  @Test("makeKey is stable for the same (pullRequestID, headRefOid, path)")
  func makeKeyStable() {
    let a = DependencyUpdateFilePatchStore.makeKey(
      pullRequestID: "pr-1",
      headRefOid: "head-a",
      path: "src/a.swift"
    )
    let b = DependencyUpdateFilePatchStore.makeKey(
      pullRequestID: "pr-1",
      headRefOid: "head-a",
      path: "src/a.swift"
    )
    let c = DependencyUpdateFilePatchStore.makeKey(
      pullRequestID: "pr-1",
      headRefOid: "head-b",
      path: "src/a.swift"
    )
    #expect(a == b)
    #expect(a != c)
  }
}
