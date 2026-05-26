import Foundation
import HarnessMonitorMirrorStore

/// iOS display copy for the shared sync status. The watch supplies its own
/// terser strings; only `systemImage` and the recovery flags are shared.
extension MirrorSyncStatus {
  var title: String {
    switch self {
    case .unpaired: "No paired Mac"
    case .demo: "Demo station"
    case .pairing: "Pairing"
    case .syncing: "Syncing"
    case .live: "Live"
    case .stale: "Sync stale"
    case .localNetworkDenied: "Local Network blocked"
    case .iCloudAccountUnavailable: "iCloud sign-in needed"
    case .paired: "Mac paired"
    case .privacy: "Privacy updated"
    case .commandQueued: "Command queued"
    case .commandCancelled: "Command cancelled"
    case .commandFailed: "Command failed"
    }
  }

  var subtitle: String {
    switch self {
    case .unpaired:
      "Pair a Mac to enable live control."
    case .demo:
      "App Review demo data is active."
    case .pairing(let stationName):
      "Connecting to \(stationName)."
    case .syncing:
      "Fetching the latest encrypted mirror."
    case .live(let date):
      "Updated \(date.formatted(.relative(presentation: .numeric)))."
    case .stale(let reason):
      reason
    case .localNetworkDenied:
      "Allow Local Network access in iOS Settings, then scan the Mac QR code again."
    case .iCloudAccountUnavailable:
      "Sign in to iCloud in Settings to resume encrypted sync."
    case .paired(let stationName):
      "\(stationName) is trusted."
    case .privacy(let message):
      message
    case .commandQueued(let date):
      "Signed at \(date.formatted(.dateTime.hour().minute().second()))."
    case .commandCancelled(let date):
      "Cancelled at \(date.formatted(.dateTime.hour().minute().second()))."
    case .commandFailed(let reason):
      reason
    }
  }
}
