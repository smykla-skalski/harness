import CloudKit
@testable import HarnessMonitorCloudKit
import XCTest

final class NeedsMeCloudKitStoreTests: XCTestCase {
    func testFetchCurrentReturnsNilWhenNoRecord() async throws {
        let stub = StubNeedsMeCloudKitDatabase()
        let store = NeedsMeCloudKitStore(database: stub)

        let fetched = try await store.fetchCurrent()

        XCTAssertNil(fetched)
        let fetchCount = await stub.fetchCallCount
        XCTAssertEqual(fetchCount, 1)
    }

    func testFetchCurrentReturnsExistingSnapshot() async throws {
        let stub = StubNeedsMeCloudKitDatabase()
        let stored = NeedsMeSnapshot(
            count: 4,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            revision: 12
        )
        await stub.setStored(stored)
        let store = NeedsMeCloudKitStore(database: stub)

        let fetched = try await store.fetchCurrent()

        XCTAssertEqual(fetched, stored)
    }

    func testUpsertCreatesRecordOnFirstCall() async throws {
        let stub = StubNeedsMeCloudKitDatabase()
        let store = NeedsMeCloudKitStore(database: stub)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

        let revision = try await store.upsert(count: 5, updatedAt: timestamp)

        XCTAssertEqual(revision, 1)
        let lastUpserted = await stub.lastUpserted
        XCTAssertEqual(lastUpserted?.count, 5)
        XCTAssertEqual(lastUpserted?.updatedAt, timestamp)
        XCTAssertEqual(lastUpserted?.revision, 1)
    }

    func testUpsertMonotonicallyIncrementsRevision() async throws {
        let stub = StubNeedsMeCloudKitDatabase()
        let store = NeedsMeCloudKitStore(database: stub)
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        let r1 = try await store.upsert(count: 3, updatedAt: base)
        let r2 = try await store.upsert(count: 4, updatedAt: base.addingTimeInterval(60))
        let r3 = try await store.upsert(count: 2, updatedAt: base.addingTimeInterval(120))

        XCTAssertEqual(r1, 1)
        XCTAssertEqual(r2, 2)
        XCTAssertEqual(r3, 3)
    }

    func testUpsertReusesCachedRevisionWithoutRefetching() async throws {
        let stub = StubNeedsMeCloudKitDatabase()
        let store = NeedsMeCloudKitStore(database: stub)
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        _ = try await store.upsert(count: 3, updatedAt: base)
        _ = try await store.upsert(count: 4, updatedAt: base.addingTimeInterval(60))

        let fetchCount = await stub.fetchCallCount
        XCTAssertEqual(
            fetchCount,
            1,
            "Second upsert should reuse cached revision, not re-fetch"
        )
    }

    func testFetchTranslatesNotAuthenticatedToTypedError() async {
        let stub = StubNeedsMeCloudKitDatabase()
        await stub.setFetchError(CKError(.notAuthenticated))
        let store = NeedsMeCloudKitStore(database: stub)

        do {
            _ = try await store.fetchCurrent()
            XCTFail("Expected NeedsMeCloudKitError.notAuthenticated")
        } catch let error as NeedsMeCloudKitError {
            XCTAssertEqual(error, .notAuthenticated)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testUpsertTranslatesNetworkUnavailableToTypedError() async {
        let stub = StubNeedsMeCloudKitDatabase()
        await stub.setUpsertError(CKError(.networkUnavailable))
        let store = NeedsMeCloudKitStore(database: stub)

        do {
            _ = try await store.upsert(count: 1, updatedAt: Date())
            XCTFail("Expected NeedsMeCloudKitError.networkUnavailable")
        } catch let error as NeedsMeCloudKitError {
            XCTAssertEqual(error, .networkUnavailable)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testFetchCachesSnapshotForSubsequentUpsert() async throws {
        let stub = StubNeedsMeCloudKitDatabase()
        let initial = NeedsMeSnapshot(
            count: 8,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            revision: 5
        )
        await stub.setStored(initial)
        let store = NeedsMeCloudKitStore(database: stub)

        _ = try await store.fetchCurrent()
        let nextRevision = try await store.upsert(
            count: 9,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )

        XCTAssertEqual(
            nextRevision,
            6,
            "Cached snapshot revision should be used as the baseline"
        )
        let fetchCount = await stub.fetchCallCount
        XCTAssertEqual(fetchCount, 1, "Upsert should not re-fetch when cache is populated")
    }
}

actor StubNeedsMeCloudKitDatabase: NeedsMeCloudKitDatabase {
    private(set) var stored: NeedsMeSnapshot?
    private(set) var fetchError: Error?
    private(set) var upsertError: Error?
    private(set) var fetchCallCount = 0
    private(set) var upsertCallCount = 0
    private(set) var lastUpserted: NeedsMeSnapshot?

    func setStored(_ snapshot: NeedsMeSnapshot?) {
        stored = snapshot
    }

    func setFetchError(_ error: Error?) {
        fetchError = error
    }

    func setUpsertError(_ error: Error?) {
        upsertError = error
    }

    func fetchSnapshot() async throws -> NeedsMeSnapshot? {
        fetchCallCount += 1
        if let fetchError {
            throw fetchError
        }
        return stored
    }

    func upsertSnapshot(_ snapshot: NeedsMeSnapshot) async throws {
        upsertCallCount += 1
        lastUpserted = snapshot
        if let upsertError {
            throw upsertError
        }
        stored = snapshot
    }
}
