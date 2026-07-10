import Foundation
import Observation

extension HarnessMonitorStore {
  @MainActor
  @Observable
  public final class ConnectionSlice {
    public enum Change {
      case connectionState
      case daemonStatus
      case refreshState
      case daemonActivity
      case persistedDataAvailability
      case metrics
      case remoteDaemon
    }

    @ObservationIgnored public var onChanged: ((Change) -> Void)?
    @ObservationIgnored let remoteDaemonServices: RemoteDaemonServices?
    public var remoteDaemonProfile: RemoteDaemonProfile? {
      didSet {
        guard oldValue != remoteDaemonProfile else { return }
        onChanged?(.remoteDaemon)
      }
    }
    public var remoteDaemonActionState: RemoteDaemonActionState {
      didSet {
        guard oldValue != remoteDaemonActionState else { return }
        onChanged?(.remoteDaemon)
      }
    }
    public var connectionState: ConnectionState = .idle {
      didSet {
        guard oldValue != connectionState else { return }
        onChanged?(.connectionState)
      }
    }
    public var daemonStatus: DaemonStatusReport? {
      didSet {
        guard oldValue != daemonStatus else { return }
        onChanged?(.daemonStatus)
      }
    }
    public var diagnostics: DaemonDiagnosticsReport?
    public var health: HealthResponse?
    public var isRefreshing = false {
      didSet {
        guard oldValue != isRefreshing else { return }
        onChanged?(.refreshState)
      }
    }
    public var isDiagnosticsRefreshInFlight = false
    public var isDaemonActionInFlight = false {
      didSet {
        guard oldValue != isDaemonActionInFlight else { return }
        onChanged?(.daemonActivity)
      }
    }
    public var activeTransport: TransportKind = .webSocket
    public var connectionMetrics: ConnectionMetrics = .initial {
      didSet {
        guard oldValue != connectionMetrics else { return }
        onChanged?(.metrics)
      }
    }
    public var lastRefreshTimings: HarnessMonitorRefreshTimings? {
      didSet {
        guard oldValue != lastRefreshTimings else { return }
        onChanged?(.metrics)
      }
    }
    public var connectionEvents: [ConnectionEvent] = []
    public var subscribedSessionIDs: Set<String> = []
    public var daemonLogLevel: String?
    public var isShowingCachedCatalog = false {
      didSet {
        guard oldValue != isShowingCachedCatalog else { return }
        onChanged?(.persistedDataAvailability)
      }
    }
    public var isShowingCachedSelectedSession = false {
      didSet {
        guard oldValue != isShowingCachedSelectedSession else { return }
        onChanged?(.persistedDataAvailability)
      }
    }
    public var isShowingCachedData: Bool {
      get { isShowingCachedSelectedSession }
      set { isShowingCachedSelectedSession = newValue }
    }
    public var persistedSessionCount = 0 {
      didSet {
        guard oldValue != persistedSessionCount else { return }
        onChanged?(.persistedDataAvailability)
      }
    }
    public var lastPersistedSnapshotAt: Date? {
      didSet {
        guard oldValue != lastPersistedSnapshotAt else { return }
        onChanged?(.persistedDataAvailability)
      }
    }

    init(remoteDaemonServices: RemoteDaemonServices? = nil) {
      self.remoteDaemonServices = remoteDaemonServices
      do {
        self.remoteDaemonProfile = try remoteDaemonServices?.connectionSource.activeProfile()
        self.remoteDaemonActionState = .idle
      } catch {
        self.remoteDaemonProfile = nil
        self.remoteDaemonActionState = .failed(error.localizedDescription)
      }
    }
  }
}
