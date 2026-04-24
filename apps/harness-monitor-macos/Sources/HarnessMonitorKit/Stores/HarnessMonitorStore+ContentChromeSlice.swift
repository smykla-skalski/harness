import Observation

extension HarnessMonitorStore {
  @MainActor
  @Observable
  public final class ContentChromeSlice {
    public var persistenceError: String?
    public var sessionDataAvailability: SessionDataAvailability = .live
    public var sessionStatus: SessionStatus?

    public init() {}

    internal func apply(_ state: ContentChromeState) {
      if persistenceError != state.persistenceError {
        persistenceError = state.persistenceError
      }
      if sessionDataAvailability != state.sessionDataAvailability {
        sessionDataAvailability = state.sessionDataAvailability
      }
      if sessionStatus != state.sessionStatus {
        sessionStatus = state.sessionStatus
      }
    }
  }
}
