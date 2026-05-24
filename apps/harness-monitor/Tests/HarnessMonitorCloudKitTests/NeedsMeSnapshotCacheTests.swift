import Foundation
@testable import HarnessMonitorCloudKit
import XCTest

final class NeedsMeSnapshotCacheTests: XCTestCase {
    func testInMemoryCacheReturnsNilWhenEmpty() async {
        let cache = InMemoryNeedsMeSnapshotCache()
        let loaded = await cache.load()
        XCTAssertNil(loaded)
    }

    func testInMemoryCacheReturnsInitialValue() async {
        let snapshot = NeedsMeSnapshot(
            count: 3,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            revision: 1
        )
        let cache = InMemoryNeedsMeSnapshotCache(initial: snapshot)
        let loaded = await cache.load()
        XCTAssertEqual(loaded, snapshot)
    }

    func testInMemoryCacheRoundTrip() async {
        let cache = InMemoryNeedsMeSnapshotCache()
        let snapshot = NeedsMeSnapshot(
            count: 5,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            revision: 7
        )
        await cache.save(snapshot)
        let loaded = await cache.load()
        XCTAssertEqual(loaded, snapshot)
    }

    func testInMemoryCacheOverwritesPriorValue() async {
        let initial = NeedsMeSnapshot(
            count: 1,
            updatedAt: Date(timeIntervalSince1970: 1),
            revision: 1
        )
        let cache = InMemoryNeedsMeSnapshotCache(initial: initial)
        let next = NeedsMeSnapshot(
            count: 9,
            updatedAt: Date(timeIntervalSince1970: 2),
            revision: 2
        )
        await cache.save(next)
        let loaded = await cache.load()
        XCTAssertEqual(loaded, next)
    }

    func testFileCacheLoadReturnsNilForMissingFile() async {
        let url = uniqueTempFileURL()
        let cache = FileNeedsMeSnapshotCache(fileURL: url)
        let loaded = await cache.load()
        XCTAssertNil(loaded)
    }

    func testFileCacheRoundTripPersistsAcrossInstances() async {
        let url = uniqueTempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = FileNeedsMeSnapshotCache(fileURL: url)
        let snapshot = NeedsMeSnapshot(
            count: 12,
            updatedAt: Date(timeIntervalSince1970: 1_700_001_234),
            revision: 5
        )
        await writer.save(snapshot)
        let reader = FileNeedsMeSnapshotCache(fileURL: url)
        let loaded = await reader.load()
        XCTAssertEqual(loaded, snapshot)
    }

    func testFileCacheLoadReturnsNilOnCorruptJSON() async {
        let url = uniqueTempFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? Data("not json".utf8).write(to: url)
        let cache = FileNeedsMeSnapshotCache(fileURL: url)
        let loaded = await cache.load()
        XCTAssertNil(loaded)
    }

    func testFileCacheSaveCreatesParentDirectory() async {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "needs-me-cache-test-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: parent) }
        let url = parent.appendingPathComponent("nested").appendingPathComponent("file.json")
        let cache = FileNeedsMeSnapshotCache(fileURL: url)
        let snapshot = NeedsMeSnapshot(
            count: 1,
            updatedAt: Date(timeIntervalSince1970: 1),
            revision: 1
        )
        await cache.save(snapshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let reloaded = await cache.load()
        XCTAssertEqual(reloaded, snapshot)
    }

    func testFileCacheDefaultURLLivesUnderCaches() {
        let url = FileNeedsMeSnapshotCache.defaultFileURL()
        let path = url.path
        XCTAssertTrue(
            path.contains("Caches/io.harnessmonitor.cloudkit")
                || path.contains("io.harnessmonitor.cloudkit"),
            "Expected default URL under Library/Caches/io.harnessmonitor.cloudkit, got \(path)"
        )
        XCTAssertEqual(url.lastPathComponent, "needs-me-snapshot.json")
    }

    private func uniqueTempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("needs-me-cache-test-\(UUID().uuidString).json")
    }
}
