import CloudKit
import Foundation

public struct NeedsMeSnapshot: Sendable, Equatable {
    public let count: Int64
    public let updatedAt: Date
    public let revision: Int64

    public init(count: Int64, updatedAt: Date, revision: Int64) {
        self.count = count
        self.updatedAt = updatedAt
        self.revision = revision
    }
}

extension NeedsMeSnapshot {
    public static let countFieldKey = "count"
    public static let updatedAtFieldKey = "updatedAt"
    public static let revisionFieldKey = "revision"

    public init?(record: CKRecord) {
        guard
            let count = record[Self.countFieldKey] as? Int64,
            let updatedAt = record[Self.updatedAtFieldKey] as? Date,
            let revision = record[Self.revisionFieldKey] as? Int64
        else {
            return nil
        }
        self.count = count
        self.updatedAt = updatedAt
        self.revision = revision
    }

    public func apply(to record: CKRecord) {
        record[Self.countFieldKey] = count as CKRecordValue
        record[Self.updatedAtFieldKey] = updatedAt as CKRecordValue
        record[Self.revisionFieldKey] = revision as CKRecordValue
    }
}
