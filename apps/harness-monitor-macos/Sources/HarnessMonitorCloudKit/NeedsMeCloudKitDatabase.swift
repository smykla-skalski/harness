import CloudKit
import Foundation

public protocol NeedsMeCloudKitDatabase: Sendable {
    func fetchSnapshot() async throws -> NeedsMeSnapshot?
    func upsertSnapshot(_ snapshot: NeedsMeSnapshot) async throws
}

public struct LiveCloudKitDatabase: NeedsMeCloudKitDatabase {
    public init() {}

    public func fetchSnapshot() async throws -> NeedsMeSnapshot? {
        let database = CloudKitContainer.privateDatabase()
        let recordID = CloudKitContainer.singletonRecordID
        do {
            let record = try await database.record(for: recordID)
            return NeedsMeSnapshot(record: record)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    public func upsertSnapshot(_ snapshot: NeedsMeSnapshot) async throws {
        let database = CloudKitContainer.privateDatabase()
        let recordID = CloudKitContainer.singletonRecordID
        let record: CKRecord
        do {
            record = try await database.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(
                recordType: CloudKitContainer.recordType,
                recordID: recordID
            )
        }
        snapshot.apply(to: record)
        _ = try await database.save(record)
    }
}
