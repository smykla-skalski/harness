import CloudKit
@testable import HarnessMonitorCloudKit
import XCTest

final class NeedsMeSnapshotCodableTests: XCTestCase {
    func testInitFromRecordPopulatesAllFields() {
        let record = CKRecord(
            recordType: CloudKitContainer.recordType,
            recordID: CloudKitContainer.singletonRecordID
        )
        record[NeedsMeSnapshot.countFieldKey] = Int64(7) as CKRecordValue
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        record[NeedsMeSnapshot.updatedAtFieldKey] = timestamp as CKRecordValue
        record[NeedsMeSnapshot.revisionFieldKey] = Int64(42) as CKRecordValue

        let snapshot = NeedsMeSnapshot(record: record)

        XCTAssertEqual(snapshot?.count, 7)
        XCTAssertEqual(snapshot?.updatedAt, timestamp)
        XCTAssertEqual(snapshot?.revision, 42)
    }

    func testInitFromRecordReturnsNilWhenCountMissing() {
        let record = CKRecord(
            recordType: CloudKitContainer.recordType,
            recordID: CloudKitContainer.singletonRecordID
        )
        record[NeedsMeSnapshot.updatedAtFieldKey] = Date() as CKRecordValue
        record[NeedsMeSnapshot.revisionFieldKey] = Int64(1) as CKRecordValue

        XCTAssertNil(NeedsMeSnapshot(record: record))
    }

    func testApplyWritesAllFieldsToRecord() {
        let snapshot = NeedsMeSnapshot(
            count: 3,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_500),
            revision: 5
        )
        let record = CKRecord(
            recordType: CloudKitContainer.recordType,
            recordID: CloudKitContainer.singletonRecordID
        )

        snapshot.apply(to: record)

        XCTAssertEqual(record[NeedsMeSnapshot.countFieldKey] as? Int64, 3)
        XCTAssertEqual(
            record[NeedsMeSnapshot.updatedAtFieldKey] as? Date,
            Date(timeIntervalSince1970: 1_700_000_500)
        )
        XCTAssertEqual(record[NeedsMeSnapshot.revisionFieldKey] as? Int64, 5)
    }

    func testRoundTripPreservesValues() {
        let original = NeedsMeSnapshot(
            count: 11,
            updatedAt: Date(timeIntervalSince1970: 1_700_001_000),
            revision: 99
        )
        let record = CKRecord(
            recordType: CloudKitContainer.recordType,
            recordID: CloudKitContainer.singletonRecordID
        )
        original.apply(to: record)

        let roundTripped = NeedsMeSnapshot(record: record)

        XCTAssertEqual(roundTripped, original)
    }
}
