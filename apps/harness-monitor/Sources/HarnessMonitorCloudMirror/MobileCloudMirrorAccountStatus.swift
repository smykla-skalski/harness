import CloudKit
import Foundation

public enum MobileCloudMirrorAccountAvailability: Sendable, Equatable {
  case available
  case unavailable
}

/// Classifies an error from a mirror fetch by whether the iCloud account itself is the blocker
/// (signed out or temporarily unavailable) versus a transient network, zone, or data error.
/// CloudKit reports account problems as `CKError.notAuthenticated` /
/// `CKError.accountTemporarilyUnavailable`, sometimes nested inside a wrapping `NSError`.
public func mobileCloudMirrorAccountAvailability(
  for error: any Error
) -> MobileCloudMirrorAccountAvailability {
  mobileCloudMirrorNSErrorTreeIndicatesAccountUnavailable(error as NSError)
    ? .unavailable
    : .available
}

private func mobileCloudMirrorNSErrorTreeIndicatesAccountUnavailable(
  _ error: NSError,
  depth: Int = 0
) -> Bool {
  guard depth < 4 else {
    return false
  }
  if error.domain == CKError.errorDomain,
    let code = CKError.Code(rawValue: error.code),
    code == .notAuthenticated || code == .accountTemporarilyUnavailable
  {
    return true
  }
  for value in error.userInfo.values {
    if let nested = value as? NSError,
      mobileCloudMirrorNSErrorTreeIndicatesAccountUnavailable(nested, depth: depth + 1)
    {
      return true
    }
  }
  return false
}
