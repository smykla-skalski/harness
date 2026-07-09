import Foundation
import HarnessMonitorKit

public enum AutomationPolicyToastCommandKind: String, Codable, Equatable, Sendable {
  case show
  case update
  case hide
}

public struct AutomationPolicyToastCommand: Codable, Equatable, Sendable {
  public var key: String
  public var kind: AutomationPolicyToastCommandKind
  public var title: String?
  public var message: String?
  public var position: ActionFeedback.Position?

  private enum CodingKeys: String, CodingKey {
    case key
    case kind
    case title
    case message
    case position
  }

  public init(
    key: String = "default",
    kind: AutomationPolicyToastCommandKind,
    title: String? = nil,
    message: String? = nil,
    position: ActionFeedback.Position? = nil
  ) {
    self.key = key
    self.kind = kind
    self.title = title
    self.message = message
    self.position = position
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    key = try container.decodeIfPresent(String.self, forKey: .key) ?? "default"
    kind = try container.decode(AutomationPolicyToastCommandKind.self, forKey: .kind)
    title = try container.decodeIfPresent(String.self, forKey: .title)
    message = try container.decodeIfPresent(String.self, forKey: .message)
    position = try container.decodeIfPresent(ActionFeedback.Position.self, forKey: .position)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(key, forKey: .key)
    try container.encode(kind, forKey: .kind)
    try container.encodeIfPresent(title, forKey: .title)
    try container.encodeIfPresent(message, forKey: .message)
    try container.encodeIfPresent(position, forKey: .position)
  }
}

public struct AutomationPolicyExecutionStep: Codable, Equatable, Sendable {
  public var nodeID: String
  public var inputPayload: AutomationPolicyPayloadKind
  public var outputPayload: AutomationPolicyPayloadKind
  public var actions: [AutomationPolicyAction]
  public var toastCommand: AutomationPolicyToastCommand?

  private enum CodingKeys: String, CodingKey {
    case nodeID
    case inputPayload
    case outputPayload
    case actions
    case toastCommand
  }

  public init(
    nodeID: String,
    inputPayload: AutomationPolicyPayloadKind,
    outputPayload: AutomationPolicyPayloadKind,
    actions: [AutomationPolicyAction],
    toastCommand: AutomationPolicyToastCommand? = nil
  ) {
    self.nodeID = nodeID
    self.inputPayload = inputPayload
    self.outputPayload = outputPayload
    self.actions = actions
    self.toastCommand = toastCommand
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    nodeID = try container.decode(String.self, forKey: .nodeID)
    inputPayload = try container.decode(AutomationPolicyPayloadKind.self, forKey: .inputPayload)
    outputPayload = try container.decode(AutomationPolicyPayloadKind.self, forKey: .outputPayload)
    actions = try container.decode([AutomationPolicyAction].self, forKey: .actions)
    toastCommand = try container.decodeIfPresent(
      AutomationPolicyToastCommand.self,
      forKey: .toastCommand
    )
  }
}

public struct AutomationPolicyFanOutBranch: Codable, Equatable, Sendable {
  public var outputPortID: String
  public var targetNodeID: String
  public var actions: [AutomationPolicyAction]
  public var toastCommand: AutomationPolicyToastCommand?

  private enum CodingKeys: String, CodingKey {
    case outputPortID
    case targetNodeID
    case actions
    case toastCommand
  }

  public init(
    outputPortID: String,
    targetNodeID: String,
    actions: [AutomationPolicyAction],
    toastCommand: AutomationPolicyToastCommand? = nil
  ) {
    self.outputPortID = outputPortID
    self.targetNodeID = targetNodeID
    self.actions = actions
    self.toastCommand = toastCommand
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    outputPortID = try container.decode(String.self, forKey: .outputPortID)
    targetNodeID = try container.decode(String.self, forKey: .targetNodeID)
    actions = try container.decode([AutomationPolicyAction].self, forKey: .actions)
    toastCommand = try container.decodeIfPresent(
      AutomationPolicyToastCommand.self,
      forKey: .toastCommand
    )
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
