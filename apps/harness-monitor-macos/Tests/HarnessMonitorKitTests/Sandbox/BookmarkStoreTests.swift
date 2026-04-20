import XCTest

@testable import HarnessMonitorKit

final class BookmarkStoreTests: XCTestCase {
  func testAddThenReloadRoundTrips() async throws {
    let dir = try makeTempDir()
    let store = BookmarkStore(containerURL: dir)
    let tmp = FileManager.default.temporaryDirectory

    let record = try await store.add(url: tmp, kind: .projectRoot)
    XCTAssertEqual(record.displayName, tmp.lastPathComponent)
    XCTAssertFalse(record.bookmarkData.isEmpty)

    let reloaded = BookmarkStore(containerURL: dir)
    let all = await reloaded.all()
    XCTAssertEqual(all.count, 1)
    XCTAssertEqual(all.first?.id, record.id)
  }

  func testMRUCapEvictsOldest() async throws {
    let dir = try makeTempDir()
    let store = BookmarkStore(containerURL: dir)
    let tmp = FileManager.default.temporaryDirectory

    for _ in 0..<(BookmarkStore.mruCap + 5) {
      _ = try await store.add(url: tmp, kind: .projectRoot)
    }
    let all = await store.all()
    XCTAssertEqual(all.count, BookmarkStore.mruCap)
  }

  func testUnsupportedSchemaVersionThrows() async throws {
    let dir = try makeTempDir()
    let sandboxDir = dir.appendingPathComponent("sandbox", isDirectory: true)
    try FileManager.default.createDirectory(at: sandboxDir, withIntermediateDirectories: true)
    let url = sandboxDir.appendingPathComponent("bookmarks.json")
    try Data(#"{"schemaVersion": 99, "bookmarks": []}"#.utf8).write(to: url)

    let store = BookmarkStore(containerURL: dir)
    do {
      _ = try await store.loadAndValidate()
      XCTFail("expected throw")
    } catch let BookmarkStoreError.unsupportedSchemaVersion(found, expected) {
      XCTAssertEqual(found, 99)
      XCTAssertEqual(expected, BookmarkStore.PersistedStore.currentSchemaVersion)
    }
  }

  func testResolveReturnsScopedURL() async throws {
    let dir = try makeTempDir()
    let store = BookmarkStore(containerURL: dir)
    let tmp = FileManager.default.temporaryDirectory

    let record = try await store.add(url: tmp, kind: .projectRoot)
    let resolved = try await store.resolve(id: record.id)
    XCTAssertEqual(
      resolved.url.resolvingSymlinksInPath().path,
      tmp.resolvingSymlinksInPath().path
    )
    XCTAssertFalse(resolved.isStale)
  }

  private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("BookmarkStoreTests-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }
}
