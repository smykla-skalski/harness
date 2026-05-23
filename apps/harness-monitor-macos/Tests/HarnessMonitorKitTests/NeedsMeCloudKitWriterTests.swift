import CloudKit
import XCTest

@testable import HarnessMonitorCloudKit
@testable import HarnessMonitorKit

@MainActor
final class NeedsMeCloudKitWriterTests: XCTestCase {
  func testFirstSubmitWritesCount() async {
    let stub = StubDatabase()
    let store = NeedsMeCloudKitStore(database: stub)
    let writer = NeedsMeCloudKitWriter(store: store, debounceInterval: .zero)

    writer.submit(count: 5)
    await writer.flush()

    let upserts = await stub.upsertCount
    let last = await stub.stored
    XCTAssertEqual(upserts, 1)
    XCTAssertEqual(last?.count, 5)
  }

  func testRepeatedSameCountSkipsRedundantWrite() async {
    let stub = StubDatabase()
    let store = NeedsMeCloudKitStore(database: stub)
    let writer = NeedsMeCloudKitWriter(store: store, debounceInterval: .zero)

    writer.submit(count: 7)
    await writer.flush()
    writer.submit(count: 7)
    await writer.flush()

    let upserts = await stub.upsertCount
    XCTAssertEqual(upserts, 1, "Same count should not retrigger a write")
  }

  func testRapidSubmitsCoalesceToLastValue() async {
    let stub = StubDatabase()
    let store = NeedsMeCloudKitStore(database: stub)
    let writer = NeedsMeCloudKitWriter(store: store, debounceInterval: .zero)

    writer.submit(count: 3)
    writer.submit(count: 5)
    writer.submit(count: 9)
    await writer.flush()

    let upserts = await stub.upsertCount
    let last = await stub.stored
    XCTAssertEqual(upserts, 1, "Pending submits should be cancelled by later submits")
    XCTAssertEqual(last?.count, 9, "Final submitted count should be the one written")
  }

  func testDifferentCountsAfterFlushBothWrite() async {
    let stub = StubDatabase()
    let store = NeedsMeCloudKitStore(database: stub)
    let writer = NeedsMeCloudKitWriter(store: store, debounceInterval: .zero)

    writer.submit(count: 4)
    await writer.flush()
    writer.submit(count: 6)
    await writer.flush()

    let upserts = await stub.upsertCount
    let last = await stub.stored
    XCTAssertEqual(upserts, 2)
    XCTAssertEqual(last?.count, 6)
  }

  func testNotAuthenticatedIsSoftFailed() async {
    let stub = StubDatabase()
    await stub.setUpsertError(CKError(.notAuthenticated))
    let store = NeedsMeCloudKitStore(database: stub)
    let writer = NeedsMeCloudKitWriter(store: store, debounceInterval: .zero)

    writer.submit(count: 5)
    await writer.flush()

    let upserts = await stub.upsertCount
    XCTAssertEqual(upserts, 1, "Writer should still attempt the call")
    let last = await stub.stored
    XCTAssertNil(last, "Stub did not store because it threw")

    writer.submit(count: 5)
    await writer.flush()
    let upsertsAfterRetry = await stub.upsertCount
    XCTAssertEqual(
      upsertsAfterRetry,
      2,
      "After soft-failure, identical count should still retry on next submit"
    )
  }

  func testFlushOnEmptyWriterIsHarmless() async {
    let stub = StubDatabase()
    let store = NeedsMeCloudKitStore(database: stub)
    let writer = NeedsMeCloudKitWriter(store: store, debounceInterval: .zero)

    await writer.flush()

    let upserts = await stub.upsertCount
    XCTAssertEqual(upserts, 0)
  }
}

actor StubDatabase: NeedsMeCloudKitDatabase {
  private(set) var stored: NeedsMeSnapshot?
  private(set) var upsertError: Error?
  private(set) var upsertCount = 0
  private(set) var fetchCount = 0

  func setUpsertError(_ error: Error?) {
    upsertError = error
  }

  func fetchSnapshot() async throws -> NeedsMeSnapshot? {
    fetchCount += 1
    return stored
  }

  func upsertSnapshot(_ snapshot: NeedsMeSnapshot) async throws {
    upsertCount += 1
    if let upsertError {
      throw upsertError
    }
    stored = snapshot
  }
}
