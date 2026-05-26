import Foundation
import HarnessMonitorMirrorStore

/// Terse watch display copy for the shared sync status. The smaller screen
/// keeps these shorter than the iOS strings; `systemImage` and the recovery
/// flags come from the framework.
extension MirrorSyncStatus {
  var title: String {
    switch self {
    case .unpaired: String(localized: "No paired Mac")
    case .demo: String(localized: "Demo station")
    case .pairing: String(localized: "Pairing")
    case .syncing: String(localized: "Syncing")
    case .live: String(localized: "Live")
    case .stale: String(localized: "Stale")
    case .localNetworkDenied: String(localized: "Network blocked")
    case .iCloudAccountUnavailable: String(localized: "iCloud needed")
    case .paired: String(localized: "Mac paired")
    case .privacy: String(localized: "Privacy")
    case .commandQueued: String(localized: "Command queued")
    case .commandCancelled: String(localized: "Command cancelled")
    case .commandFailed: String(localized: "Command failed")
    }
  }

  var subtitle: String {
    switch self {
    case .unpaired:
      String(localized: "Open iPhone pairing")
    case .demo:
      String(localized: "App Review demo")
    case .pairing(let stationName):
      String(localized: "Connecting to \(stationName)")
    case .syncing:
      String(localized: "Fetching mirror")
    case .live(let date):
      String(localized: "Updated \(date.formatted(.relative(presentation: .numeric)))")
    case .stale(let reason), .commandFailed(let reason):
      reason
    case .localNetworkDenied:
      String(localized: "Allow Local Network on iPhone")
    case .iCloudAccountUnavailable:
      String(localized: "Sign in to iCloud")
    case .paired(let stationName):
      String(localized: "\(stationName) trusted")
    case .privacy(let message):
      message
    case .commandQueued(let date):
      String(localized: "Signed \(date.formatted(.dateTime.hour().minute()))")
    case .commandCancelled(let date):
      String(localized: "Cancelled \(date.formatted(.dateTime.hour().minute()))")
    }
  }
}
