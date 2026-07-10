import Foundation
import HarnessMonitorMirrorStore

/// iOS display copy for the shared sync status. The watch supplies its own
/// terser strings; only `systemImage` and the recovery flags are shared.
extension MirrorSyncStatus {
  var title: String {
    switch self {
    case .unpaired: String(localized: "No paired Mac")
    case .demo: String(localized: "Demo station")
    case .pairing: String(localized: "Pairing")
    case .syncing: String(localized: "Syncing")
    case .live: String(localized: "Live")
    case .stale: String(localized: "Sync stale")
    case .localNetworkDenied: String(localized: "Local Network blocked")
    case .iCloudAccountUnavailable: String(localized: "iCloud sign-in needed")
    case .paired: String(localized: "Mac paired")
    case .privacy: String(localized: "Privacy updated")
    case .commandQueued: String(localized: "Command queued")
    case .commandCompleted: String(localized: "Command completed")
    case .commandCancelled: String(localized: "Command cancelled")
    case .commandFailed: String(localized: "Command failed")
    }
  }

  var subtitle: String {
    switch self {
    case .unpaired:
      String(localized: "Pair a Mac to enable live control")
    case .demo:
      String(localized: "App Review demo data is active")
    case .pairing(let stationName):
      String(localized: "Connecting to \(stationName)")
    case .syncing:
      String(localized: "Fetching the latest encrypted mirror")
    case .live(let date):
      String(localized: "Updated \(date.formatted(.relative(presentation: .numeric)))")
    case .stale(let reason):
      reason
    case .localNetworkDenied:
      String(
        localized: "Allow Local Network access in iOS Settings, then scan the Mac QR code again")
    case .iCloudAccountUnavailable:
      String(localized: "Sign in to iCloud in Settings to resume encrypted sync")
    case .paired(let stationName):
      String(localized: "\(stationName) is trusted")
    case .privacy(let message):
      message
    case .commandQueued(let date):
      String(localized: "Signed at \(date.formatted(.dateTime.hour().minute().second()))")
    case .commandCompleted(let date):
      String(localized: "Completed at \(date.formatted(.dateTime.hour().minute().second()))")
    case .commandCancelled(let date):
      String(localized: "Cancelled at \(date.formatted(.dateTime.hour().minute().second()))")
    case .commandFailed(let reason):
      reason
    }
  }
}
