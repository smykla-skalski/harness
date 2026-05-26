import CloudKit
import Foundation

public enum CloudKitContainer {
  public static let identifier = "iCloud.io.harnessmonitor"
  public static let recordType = "NeedsMeSnapshot"
  public static let singletonRecordName = "current"
  // Keep the CloudKit client alive for the process lifetime. Temporary
  // container/database instances can fail mid-request with "Client went away".
  private static let sharedContainer = CKContainer(identifier: identifier)
  private static let sharedPrivateDatabase = sharedContainer.privateCloudDatabase

  public static func container() -> CKContainer {
    sharedContainer
  }

  public static func privateDatabase() -> CKDatabase {
    sharedPrivateDatabase
  }

  public static var singletonRecordID: CKRecord.ID {
    CKRecord.ID(recordName: singletonRecordName)
  }
}
