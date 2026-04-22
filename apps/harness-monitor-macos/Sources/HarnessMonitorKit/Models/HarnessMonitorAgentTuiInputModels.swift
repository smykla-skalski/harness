import Foundation

public struct AgentTuiInputRequest: Codable, Equatable, Sendable {
  public let input: AgentTuiInput?
  public let sequence: AgentTuiInputSequence?

  public init(input: AgentTuiInput) {
    self.input = input
    self.sequence = nil
  }

  public init(sequence: AgentTuiInputSequence) throws {
    try sequence.validate()
    self.input = nil
    self.sequence = sequence
  }

  public var replayedInputs: [AgentTuiInput] {
    if let input {
      return [input]
    }
    return sequence?.steps.map(\.input) ?? []
  }

  public func validate() throws {
    switch (input, sequence) {
    case (.some, nil):
      break
    case (nil, .some(let sequence)):
      try sequence.validate()
    default:
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: [],
          debugDescription: "Exactly one of input or sequence must be present."
        )
      )
    }
  }

  enum CodingKeys: String, CodingKey {
    case input
    case sequence
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    input = try container.decodeIfPresent(AgentTuiInput.self, forKey: .input)
    sequence = try container.decodeIfPresent(AgentTuiInputSequence.self, forKey: .sequence)
    try validate()
  }

  public func encode(to encoder: Encoder) throws {
    try validate()
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(input, forKey: .input)
    try container.encodeIfPresent(sequence, forKey: .sequence)
  }
}

public struct AgentTuiInputSequence: Codable, Equatable, Sendable {
  public let steps: [AgentTuiInputSequenceStep]

  public init(steps: [AgentTuiInputSequenceStep]) {
    self.steps = steps
  }

  public func validate() throws {
    guard let first = steps.first else {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: [],
          debugDescription: "Input sequences must contain at least one step."
        )
      )
    }
    guard first.delayBeforeMs == 0 else {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: [],
          debugDescription: "The first input sequence step must have delay_before_ms = 0."
        )
      )
    }
  }
}

public struct AgentTuiInputSequenceStep: Codable, Equatable, Sendable {
  public let delayBeforeMs: Int
  public let input: AgentTuiInput

  public init(delayBeforeMs: Int, input: AgentTuiInput) {
    self.delayBeforeMs = delayBeforeMs
    self.input = input
  }

  enum CodingKeys: String, CodingKey {
    case delayBeforeMs = "delay_before_ms"
    case input
  }
}

public enum AgentTuiInput: Codable, Equatable, Sendable {
  case text(String)
  case paste(String)
  case key(AgentTuiKey)
  case control(Character)
  case rawBytesBase64(String)

  enum CodingKeys: String, CodingKey {
    case type
    case text
    case key
    case data
  }

  enum InputType: String, Codable {
    case text
    case paste
    case key
    case control
    case rawBytesBase64 = "raw_bytes_base64"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(InputType.self, forKey: .type)
    switch type {
    case .text:
      self = .text(try container.decode(String.self, forKey: .text))
    case .paste:
      self = .paste(try container.decode(String.self, forKey: .text))
    case .key:
      self = .key(try container.decode(AgentTuiKey.self, forKey: .key))
    case .control:
      let value = try container.decode(String.self, forKey: .key)
      guard let character = value.first, value.count == 1 else {
        throw DecodingError.dataCorruptedError(
          forKey: .key,
          in: container,
          debugDescription: "Control key must be exactly one character."
        )
      }
      self = .control(character)
    case .rawBytesBase64:
      self = .rawBytesBase64(try container.decode(String.self, forKey: .data))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .text(let text):
      try container.encode(InputType.text, forKey: .type)
      try container.encode(text, forKey: .text)
    case .paste(let text):
      try container.encode(InputType.paste, forKey: .type)
      try container.encode(text, forKey: .text)
    case .key(let key):
      try container.encode(InputType.key, forKey: .type)
      try container.encode(key, forKey: .key)
    case .control(let key):
      try container.encode(InputType.control, forKey: .type)
      try container.encode(String(key), forKey: .key)
    case .rawBytesBase64(let data):
      try container.encode(InputType.rawBytesBase64, forKey: .type)
      try container.encode(data, forKey: .data)
    }
  }
}
