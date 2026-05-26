import Foundation
import HarnessMonitorMirrorStore

/// Terse watch display copy for the shared sync status. The smaller screen
/// keeps these shorter than the iOS strings; `systemImage` and the recovery
/// flags come from the framework.
extension MirrorSyncStatus {
  var title: String {
    switch self {
    case .unpaired: "No paired Mac"
    case .demo: "Demo station"
    case .pairing: "Pairing"
    case .syncing: "Syncing"
    case .live: "Live"
    case .stale: "Stale"
    case .localNetworkDenied: "Network blocked"
    case .iCloudAccountUnavailable: "iCloud needed"
    case .paired: "Mac paired"
    case .privacy: "Privacy"
    case .commandQueued: "Command queued"
    case .commandCancelled: "Command cancelled"
    case .commandFailed: "Command failed"
    }
  }

  var subtitle: String {
    switch self {
    case .unpaired:
      "Open iPhone pairing"
    case .demo:
      "App Review demo"
    case .pairing(let stationName):
      "Connecting to \(stationName)"
    case .syncing:
      "Fetching mirror"
    case .live(let date):
      "Updated \(date.formatted(.relative(presentation: .numeric)))"
    case .stale(let reason), .commandFailed(let reason):
      reason
    case .localNetworkDenied:
      "Allow Local Network on iPhone"
    case .iCloudAccountUnavailable:
      "Sign in to iCloud"
    case .paired(let stationName):
      "\(stationName) trusted"
    case .privacy(let message):
      message
    case .commandQueued(let date):
      "Signed \(date.formatted(.dateTime.hour().minute()))"
    case .commandCancelled(let date):
      "Cancelled \(date.formatted(.dateTime.hour().minute()))"
    }
  }
}
