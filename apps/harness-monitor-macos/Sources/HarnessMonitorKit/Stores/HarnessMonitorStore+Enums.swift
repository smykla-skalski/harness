import Foundation

extension HarnessMonitorStore {
  public struct ExternalSessionAttachOutcome: Equatable, Sendable {
    public let message: String
    public let succeeded: Bool

    public init(message: String, succeeded: Bool) {
      self.message = message
      self.succeeded = succeeded
    }
  }

  public enum ConnectionState: Equatable {
    case idle
    case connecting
    case online
    case offline(String)
  }

  public enum SessionFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case active
    case ended

    public var id: String { rawValue }

    public var title: String {
      rawValue.capitalized
    }

    func includes(_ status: SessionStatus) -> Bool {
      switch self {
      case .active:
        status != .ended
      case .all:
        true
      case .ended:
        status == .ended
      }
    }
  }

  public enum InspectorSelection: Equatable, Sendable {
    case none
    case task(String)
    case signal(String)
    case observer
  }

  public enum PendingConfirmation: Equatable {
    case endSession(sessionID: String, actorID: String)
    case removeAgent(sessionID: String, agentID: String, actorID: String)
  }

  public enum HostBridgeCapabilityIssue: Equatable {
    case unavailable
    case excluded
  }

  public enum HostBridgeCapabilityState: Equatable {
    case ready
    case unavailable
    case excluded
  }

  public enum HostBridgeCapabilityMutationResult: Equatable {
    case success
    case requiresForce(String)
    case failed
  }

  public enum PresentedSheet: Identifiable, Equatable {
    case sendSignal(agentID: String)
    case newSession
    case attachExternal(bookmarkId: String, preview: SessionDiscoveryProbe.Preview?)
    case signalDetail(signalID: String)

    public var id: String {
      switch self {
      case .sendSignal(let agentID): "sendSignal:\(agentID)"
      case .newSession: "newSession"
      case .attachExternal(let bookmarkId, _): "attachExternal:\(bookmarkId)"
      case .signalDetail(let signalID): "signalDetail:\(signalID)"
      }
    }
  }
}
