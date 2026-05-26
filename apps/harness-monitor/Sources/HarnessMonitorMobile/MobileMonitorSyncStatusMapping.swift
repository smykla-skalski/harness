import Foundation
import HarnessMonitorCloudMirror

let mobileMonitorNoEncryptedMirrorMessage =
  "Mac has not published an encrypted mirror for this device yet. "
  + "Keep Harness Monitor open on your Mac; this app will retry automatically."

func mobileMonitorSyncStatus(for error: any Error) -> MobileMonitorSyncStatus {
  if mobileMonitorErrorIsLocalNetworkDenied(error) {
    return .localNetworkDenied
  }
  if mobileCloudMirrorAccountAvailability(for: error) == .unavailable {
    return .iCloudAccountUnavailable
  }
  return .stale(mobileMonitorReadableErrorDescription(error))
}

func mobileMonitorReadableErrorDescription(_ error: any Error) -> String {
  let description = (error as NSError).localizedDescription
    .trimmingCharacters(in: .whitespacesAndNewlines)
  return description.isEmpty ? String(describing: error) : description
}

func mobileMonitorErrorIsLocalNetworkDenied(_ error: any Error) -> Bool {
  mobileMonitorNSErrorTreeContainsLocalNetworkDenied(error as NSError)
}

func mobileMonitorNSErrorTreeContainsLocalNetworkDenied(
  _ error: NSError,
  depth: Int = 0
) -> Bool {
  guard depth < 4 else {
    return false
  }
  let searchableText = [
    error.localizedDescription,
    String(describing: error.userInfo),
  ].joined(separator: " ")
  if searchableText.localizedCaseInsensitiveContains("Local network prohibited") {
    return true
  }
  for value in error.userInfo.values {
    if let nestedError = value as? NSError,
      mobileMonitorNSErrorTreeContainsLocalNetworkDenied(nestedError, depth: depth + 1)
    {
      return true
    }
    if String(describing: value).localizedCaseInsensitiveContains("Local network prohibited") {
      return true
    }
  }
  return false
}
