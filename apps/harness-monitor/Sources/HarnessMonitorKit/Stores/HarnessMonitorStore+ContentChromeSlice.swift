import Observation

extension HarnessMonitorStore {
  @MainActor
  @Observable
  public final class ContentChromeSlice {
    public var persistenceError: String?
    public var sessionDataAvailability: SessionDataAvailability = .live
    public var sessionStatus: SessionStatus?
    public var acpBridgeBanner: AcpBridgeBannerState?
    public var mcpStatus = HarnessMonitorMCPStatusSnapshot(
      runtimeState: .disabled,
      recoveryStatus: nil
    )

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
      if acpBridgeBanner != state.acpBridgeBanner {
        acpBridgeBanner = state.acpBridgeBanner
      }
      if mcpStatus != state.mcpStatus {
        mcpStatus = state.mcpStatus
      }
    }
  }
}
