import CloudKit
import Foundation

public enum CloudKitContainer {
  public static let identifier = "iCloud.io.harnessmonitor"
  public static let recordType = "NeedsMeSnapshot"
  public static let singletonRecordName = "current"

  public static func container() -> CKContainer {
    CKContainer(identifier: identifier)
  }

  public static func privateDatabase() -> CKDatabase {
    container().privateCloudDatabase
  }

  public static var singletonRecordID: CKRecord.ID {
    CKRecord.ID(recordName: singletonRecordName)
  }
}
