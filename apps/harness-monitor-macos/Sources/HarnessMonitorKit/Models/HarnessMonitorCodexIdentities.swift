public protocol HarnessMonitorStringID: Hashable, Codable, Sendable, Identifiable,
  CustomStringConvertible
{
  var rawValue: String { get }
  init(rawValue: String)
}

extension HarnessMonitorStringID {
  public init(_ rawValue: String) {
    self.init(rawValue: rawValue)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.init(rawValue: try container.decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public var id: String { rawValue }
  public var description: String { rawValue }
}

public struct HarnessSessionID: HarnessMonitorStringID {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
}

public struct SessionAgentID: HarnessMonitorStringID {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
}

public struct ManagedAgentID: HarnessMonitorStringID {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
}

public struct RuntimeSessionID: HarnessMonitorStringID {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
}

public struct AcpDescriptorID: HarnessMonitorStringID {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
}

public struct AcpPermissionBatchID: HarnessMonitorStringID {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
}

public struct AcpPermissionRequestID: HarnessMonitorStringID {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
}

public struct CodexApprovalID: HarnessMonitorStringID {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
}

public struct CodexApprovalRequestID: HarnessMonitorStringID {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
}

public struct CodexThreadID: HarnessMonitorStringID {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
}

public struct CodexTurnID: HarnessMonitorStringID {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
}

public struct CodexItemID: HarnessMonitorStringID {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
}

extension ManagedAgentRef {
  public var managedAgentIdentity: ManagedAgentID {
    ManagedAgentID(rawValue: managedAgentID)
  }
}

extension AgentRegistration {
  public var sessionAgentIdentity: SessionAgentID {
    SessionAgentID(rawValue: sessionAgentID)
  }

  public var runtimeSessionIdentity: RuntimeSessionID? {
    runtimeSessionID.map(RuntimeSessionID.init(rawValue:))
  }

  public var managedAgentIdentity: ManagedAgentID? {
    managedAgentID.map(ManagedAgentID.init(rawValue:))
  }
}

extension ManagedAgentSnapshot {
  public var managedAgentIdentity: ManagedAgentID {
    ManagedAgentID(rawValue: managedAgentID)
  }

  public var sessionIdentity: HarnessSessionID {
    HarnessSessionID(rawValue: sessionId)
  }

  public var sessionAgentIdentity: SessionAgentID? {
    sessionAgentID.map(SessionAgentID.init(rawValue:))
  }
}

extension AgentTuiSnapshot {
  public var managedAgentIdentity: ManagedAgentID {
    ManagedAgentID(rawValue: managedAgentID)
  }

  public var sessionIdentity: HarnessSessionID {
    HarnessSessionID(rawValue: sessionId)
  }

  public var sessionAgentIdentity: SessionAgentID {
    SessionAgentID(rawValue: sessionAgentID)
  }
}

extension CodexApprovalRequest {
  public var approvalIdentity: CodexApprovalID {
    CodexApprovalID(rawValue: approvalId)
  }

  public var requestIdentity: CodexApprovalRequestID {
    CodexApprovalRequestID(rawValue: requestId)
  }

  public var threadIdentity: CodexThreadID? {
    threadId.map(CodexThreadID.init(rawValue:))
  }

  public var turnIdentity: CodexTurnID? {
    turnId.map(CodexTurnID.init(rawValue:))
  }

  public var itemIdentity: CodexItemID? {
    itemId.map(CodexItemID.init(rawValue:))
  }
}

extension CodexRunSnapshot {
  public var managedAgentIdentity: ManagedAgentID {
    ManagedAgentID(rawValue: managedAgentID)
  }

  public var sessionIdentity: HarnessSessionID {
    HarnessSessionID(rawValue: sessionId)
  }

  public var sessionAgentIdentity: SessionAgentID? {
    sessionAgentID.map(SessionAgentID.init(rawValue:))
  }

  public var threadIdentity: CodexThreadID? {
    threadId.map(CodexThreadID.init(rawValue:))
  }

  public var turnIdentity: CodexTurnID? {
    turnId.map(CodexTurnID.init(rawValue:))
  }
}
