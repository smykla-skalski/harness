import Foundation

extension HarnessMonitorStore {
  public enum PersistedSessionReason: Equatable {
    case daemonOffline(String)
    case liveDataUnavailable
  }

  public enum SessionDataAvailability: Equatable {
    case live
    case persisted(
      reason: PersistedSessionReason,
      sessionCount: Int,
      lastSnapshotAt: Date?
    )
    case unavailable(reason: PersistedSessionReason)
  }
}
