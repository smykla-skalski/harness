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
    XCTAssertFalse(record.handoffBookmarkData?.isEmpty ?? true)

    let reloaded = BookmarkStore(containerURL: dir)
    let all = await reloaded.all()
    XCTAssertEqual(all.count, 1)
    XCTAssertEqual(all.first?.id, record.id)
    XCTAssertEqual(all.first?.handoffBookmarkData, record.handoffBookmarkData)
  }

  func testMRUCapEvictsOldest() async throws {
    let dir = try makeTempDir()
    let store = BookmarkStore(containerURL: dir)

    for index in 0..<(BookmarkStore.mruCap + 5) {
      let target = try makeTempDir(named: "mru-\(index)")
      _ = try await store.add(url: target, kind: .projectRoot)
    }
    let all = await store.all()
    XCTAssertEqual(all.count, BookmarkStore.mruCap)
  }

  func testAddReusesExistingRecordForSameCanonicalPath() async throws {
    let dir = try makeTempDir()
    let store = BookmarkStore(containerURL: dir)
    let target = FileManager.default.temporaryDirectory

    let first = try await store.add(url: target, kind: .projectRoot)
    let second = try await store.add(url: target, kind: .projectRoot)
    let all = await store.all()

    XCTAssertEqual(all.count, 1)
    XCTAssertEqual(second.id, first.id)
    XCTAssertEqual(all.first?.id, first.id)
    XCTAssertEqual(all.first?.lastResolvedPath, target.standardizedFileURL.resolvingSymlinksInPath().path)
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

  func testAddRefusesToWipeFutureSchemaFile() async throws {
    let dir = try makeTempDir()
    let sandboxDir = dir.appendingPathComponent("sandbox", isDirectory: true)
    try FileManager.default.createDirectory(at: sandboxDir, withIntermediateDirectories: true)
    let url = sandboxDir.appendingPathComponent("bookmarks.json")
    let originalBytes = Data(#"{"schemaVersion": 99, "bookmarks": []}"#.utf8)
    try originalBytes.write(to: url)

    let store = BookmarkStore(containerURL: dir)
    let tmp = FileManager.default.temporaryDirectory
    do {
      _ = try await store.add(url: tmp, kind: .projectRoot)
      XCTFail("expected throw; add must never silently wipe a future-schema file")
    } catch BookmarkStoreError.unsupportedSchemaVersion {
      // expected
    }
    XCTAssertEqual(try Data(contentsOf: url), originalBytes)
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

  #if DEBUG
    func testInsertForTestingReplacesExistingRecordWithSameId() async throws {
      let dir = try makeTempDir()
      let store = BookmarkStore(containerURL: dir)
      let first = BookmarkStore.Record(
        id: "B-x",
        kind: .projectRoot,
        displayName: "first",
        lastResolvedPath: "/tmp/first",
        bookmarkData: Data([0x01]),
        handoffBookmarkData: Data([0x03])
      )
      let second = BookmarkStore.Record(
        id: "B-x",
        kind: .projectRoot,
        displayName: "second",
        lastResolvedPath: "/tmp/second",
        bookmarkData: Data([0x02]),
        handoffBookmarkData: Data([0x04])
      )
      try await store.insertForTesting(first)
      try await store.insertForTesting(second)
      let all = await store.all()
      XCTAssertEqual(all.count, 1)
      XCTAssertEqual(all.first?.displayName, "second")
    }

    func testLoadDeduplicatesById() async throws {
      let dir = try makeTempDir()
      let sandboxDir = dir.appendingPathComponent("sandbox", isDirectory: true)
      try FileManager.default.createDirectory(at: sandboxDir, withIntermediateDirectories: true)
      let url = sandboxDir.appendingPathComponent("bookmarks.json")
      // Write two records with the same id directly to bypass the store API.
      let json = """
        {
          "schemaVersion": 1,
          "bookmarks": [
            {
              "id": "B-dup",
              "kind": "project-root",
              "displayName": "dup1",
              "lastResolvedPath": "/tmp/a",
              "bookmarkData": "AA==",
              "createdAt": "2024-01-01T00:00:00Z",
              "lastAccessedAt": "2024-01-01T00:00:00Z",
              "staleCount": 0
            },
            {
              "id": "B-dup",
              "kind": "project-root",
              "displayName": "dup2",
              "lastResolvedPath": "/tmp/b",
              "bookmarkData": "AA==",
              "createdAt": "2024-01-01T00:00:00Z",
              "lastAccessedAt": "2024-01-01T00:00:00Z",
              "staleCount": 0
            }
          ]
        }
        """
      try Data(json.utf8).write(to: url)
      let store = BookmarkStore(containerURL: dir)
      let loaded = try await store.loadAndValidate()
      XCTAssertEqual(loaded.bookmarks.count, 1)
      XCTAssertEqual(loaded.bookmarks.first?.displayName, "dup1")
    }

    func testLoadDropsUITestSeedOutsideUITestStores() async throws {
      let dir = try makeTempDir()
      let sandboxDir = dir.appendingPathComponent("sandbox", isDirectory: true)
      try FileManager.default.createDirectory(at: sandboxDir, withIntermediateDirectories: true)
      let url = sandboxDir.appendingPathComponent("bookmarks.json")
      let json = """
        {
          "schemaVersion": 1,
          "bookmarks": [
            {
              "id": "B-preseed",
              "kind": "project-root",
              "displayName": "Sample Project Folder",
              "lastResolvedPath": "/tmp/sample",
              "bookmarkData": "AA==",
              "createdAt": "2024-01-01T00:00:00Z",
              "lastAccessedAt": "2024-01-01T00:00:00Z",
              "staleCount": 0
            },
            {
              "id": "B-real",
              "kind": "project-root",
              "displayName": "harness",
              "lastResolvedPath": "/tmp/harness",
              "bookmarkData": "AA==",
              "createdAt": "2024-01-01T00:00:00Z",
              "lastAccessedAt": "2024-01-01T00:00:00Z",
              "staleCount": 0
            }
          ]
        }
        """
      try Data(json.utf8).write(to: url)

      let store = BookmarkStore(containerURL: dir)
      let loaded = try await store.loadAndValidate()

      XCTAssertEqual(loaded.bookmarks.count, 1)
      XCTAssertEqual(loaded.bookmarks.first?.id, "B-real")
    }

    func testLoadKeepsUITestSeedInsideUITestStores() async throws {
      let dir = try makeTempDir()
      let sandboxDir = dir.appendingPathComponent("sandbox", isDirectory: true)
      try FileManager.default.createDirectory(at: sandboxDir, withIntermediateDirectories: true)
      let url = sandboxDir.appendingPathComponent("bookmarks.json")
      let json = """
        {
          "schemaVersion": 1,
          "bookmarks": [
            {
              "id": "B-preseed",
              "kind": "project-root",
              "displayName": "Sample Project Folder",
              "lastResolvedPath": "/tmp/sample",
              "bookmarkData": "AA==",
              "createdAt": "2024-01-01T00:00:00Z",
              "lastAccessedAt": "2024-01-01T00:00:00Z",
              "staleCount": 0
            }
          ]
        }
        """
      try Data(json.utf8).write(to: url)

      let store = BookmarkStore(containerURL: dir, allowsUITestSeedRecords: true)
      let loaded = try await store.loadAndValidate()

      XCTAssertEqual(loaded.bookmarks.count, 1)
      XCTAssertEqual(loaded.bookmarks.first?.id, "B-preseed")
    }
  #endif

  private func makeTempDir() throws -> URL {
    try makeTempDir(named: UUID().uuidString)
  }

  private func makeTempDir(named name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("BookmarkStoreTests-\(name)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }
}
