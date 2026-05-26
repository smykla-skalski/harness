import Foundation

/// When the iOS pairing bridge may activate its `WCSession`.
///
/// A `WCSession` is activated exactly once for the process lifetime, and the
/// system re-activates it only after deactivating it during a multi-watch
/// handoff. The bridge publishes pairing material on every mirror refresh, so
/// the publish path must never trigger activation - doing so makes the
/// WatchConnectivity daemon log "already in progress or activated" on every
/// refresh. Centralising the decision here keeps every activation site honest
/// and lets the rule be tested without the iOS-only WatchConnectivity types.
public enum WatchPairingSessionActivation {
  public enum Event: Sendable {
    /// The bridge created the session (process start).
    case sessionCreated
    /// A pairing payload is about to be published (runs on every refresh).
    case payloadPublish
    /// The system deactivated the session (multi-watch handoff on iOS).
    case systemDeactivated
  }

  /// Whether the bridge should call `activate()` for this event.
  public static func shouldActivate(on event: Event) -> Bool {
    switch event {
    case .sessionCreated, .systemDeactivated:
      true
    case .payloadPublish:
      false
    }
  }
}
