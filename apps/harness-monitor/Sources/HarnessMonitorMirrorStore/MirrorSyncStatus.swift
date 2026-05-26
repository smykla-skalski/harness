import Foundation

/// Sync status shared by the iOS and watch mirror stores.
///
/// The cases are the union of both platforms. The watch never emits the
/// iOS-only pairing, local-network, iCloud, paired, or privacy cases, and its
/// former `.loading` maps onto `.syncing`. Display copy (`title`/`subtitle`)
/// stays platform-specific via per-target extensions because the watch
/// deliberately uses terser wording on its smaller screen; `systemImage` and
/// the semantic recovery flags are identical across platforms and live here.
public enum MirrorSyncStatus: Equatable, Sendable {
  case unpaired
  case demo
  case pairing(String)
  case syncing
  case live(Date)
  case stale(String)
  case localNetworkDenied
  case iCloudAccountUnavailable
  case paired(String)
  case privacy(String)
  case commandQueued(Date)
  case commandCancelled(Date)
  case commandFailed(String)

  public var systemImage: String {
    switch self {
    case .unpaired: "link.badge.plus"
    case .demo: "testtube.2"
    case .pairing: "qrcode.viewfinder"
    case .syncing: "arrow.triangle.2.circlepath"
    case .live: "checkmark.icloud"
    case .stale: "exclamationmark.icloud"
    case .localNetworkDenied: "wifi.slash"
    case .iCloudAccountUnavailable: "icloud.slash"
    case .paired: "key.horizontal"
    case .privacy: "checkmark.shield"
    case .commandQueued: "checkmark.seal"
    case .commandCancelled: "xmark.seal"
    case .commandFailed: "xmark.octagon"
    }
  }

  /// Whether recovery routes the user to the system Settings app. Today only
  /// the denied Local Network permission needs a Settings trip.
  public var opensAppSettingsForRecovery: Bool {
    if case .localNetworkDenied = self {
      return true
    }
    return false
  }

  /// Whether the status reflects a sync failure the foreground loop should
  /// back off from. Drives the staleness-gated refresh interval on both apps.
  public var indicatesSyncFailure: Bool {
    switch self {
    case .stale, .localNetworkDenied, .iCloudAccountUnavailable:
      true
    case .unpaired, .demo, .pairing, .syncing, .live, .paired, .privacy,
      .commandQueued, .commandCancelled, .commandFailed:
      false
    }
  }
}
