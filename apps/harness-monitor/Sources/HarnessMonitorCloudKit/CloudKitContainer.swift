import CloudKit
import Foundation
import Security

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

  public static func hasCloudKitEntitlement() -> Bool {
    var code: SecCode?
    guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else {
      return false
    }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
      let staticCode
    else {
      return false
    }
    var signingInfo: CFDictionary?
    let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
    guard SecCodeCopySigningInformation(staticCode, flags, &signingInfo) == errSecSuccess,
      let info = signingInfo as? [String: Any],
      let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
      let containers = entitlements[
        "com.apple.developer.icloud-container-identifiers"
      ] as? [String]
    else {
      return false
    }
    return containers.contains(identifier)
  }

  public static var singletonRecordID: CKRecord.ID {
    CKRecord.ID(recordName: singletonRecordName)
  }
}
