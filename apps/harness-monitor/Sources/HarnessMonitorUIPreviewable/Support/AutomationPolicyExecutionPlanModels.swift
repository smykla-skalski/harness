import Foundation

public struct AutomationPolicyExecutionStep: Codable, Equatable, Sendable {
  public var nodeID: String
  public var inputPayload: AutomationPolicyPayloadKind
  public var outputPayload: AutomationPolicyPayloadKind
  public var actions: [AutomationPolicyAction]

  public init(
    nodeID: String,
    inputPayload: AutomationPolicyPayloadKind,
    outputPayload: AutomationPolicyPayloadKind,
    actions: [AutomationPolicyAction]
  ) {
    self.nodeID = nodeID
    self.inputPayload = inputPayload
    self.outputPayload = outputPayload
    self.actions = actions
  }
}

public struct AutomationPolicyFanOutBranch: Codable, Equatable, Sendable {
  public var outputPortID: String
  public var targetNodeID: String
  public var actions: [AutomationPolicyAction]

  public init(
    outputPortID: String,
    targetNodeID: String,
    actions: [AutomationPolicyAction]
  ) {
    self.outputPortID = outputPortID
    self.targetNodeID = targetNodeID
    self.actions = actions
  }
}

public struct AutomationPolicyFanOut: Codable, Equatable, Sendable {
  public var hubNodeID: String
  public var payload: AutomationPolicyPayloadKind
  public var branches: [AutomationPolicyFanOutBranch]

  public init(
    hubNodeID: String,
    payload: AutomationPolicyPayloadKind,
    branches: [AutomationPolicyFanOutBranch]
  ) {
    self.hubNodeID = hubNodeID
    self.payload = payload
    self.branches = branches
  }
}

public struct AutomationPolicyExecutionPlan: Codable, Equatable, Sendable {
  public var sourceNodeID: String
  public var eventSource: AutomationPolicyEventSource
  public var steps: [AutomationPolicyExecutionStep]
  public var fanOuts: [AutomationPolicyFanOut]

  private enum CodingKeys: String, CodingKey {
    case sourceNodeID
    case eventSource
    case steps
    case fanOuts
  }

  public init(
    sourceNodeID: String,
    eventSource: AutomationPolicyEventSource,
    steps: [AutomationPolicyExecutionStep],
    fanOuts: [AutomationPolicyFanOut] = []
  ) {
    self.sourceNodeID = sourceNodeID
    self.eventSource = eventSource
    self.steps = steps
    self.fanOuts = fanOuts
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    sourceNodeID = try container.decode(String.self, forKey: .sourceNodeID)
    eventSource = try container.decode(AutomationPolicyEventSource.self, forKey: .eventSource)
    steps = try container.decode([AutomationPolicyExecutionStep].self, forKey: .steps)
    fanOuts = try container.decodeIfPresent([AutomationPolicyFanOut].self, forKey: .fanOuts) ?? []
  }

  public var orderedActions: [AutomationPolicyAction] {
    var actions: [AutomationPolicyAction] = []
    for action in steps.flatMap(\.actions) where !actions.contains(action) {
      actions.append(action)
    }
    return actions
  }
}
