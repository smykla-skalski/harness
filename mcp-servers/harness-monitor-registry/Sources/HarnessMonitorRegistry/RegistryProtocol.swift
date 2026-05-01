import Foundation

public enum RegistryRequestOp: String, Sendable, Codable {
  case ping
  case listWindows
  case listElements
  case getElement
  case syncClientSnapshot
  case clearClientSnapshot
  case replacementNotice
}

public struct RegistryRequest: Sendable, Codable {
  public var id: Int
  public var op: RegistryRequestOp
  public var identifier: String?
  public var windowID: Int?
  public var kind: RegistryElementKind?
  public var clientID: UUID?
  public var clientClear: RegistryClientClearRequest?
  public var clientSnapshot: RegistryClientSnapshot?
  public var replacementNotice: RegistryReplacementNotice?

  public init(
    id: Int,
    op: RegistryRequestOp,
    identifier: String? = nil,
    windowID: Int? = nil,
    kind: RegistryElementKind? = nil,
    clientID: UUID? = nil,
    clientClear: RegistryClientClearRequest? = nil,
    clientSnapshot: RegistryClientSnapshot? = nil,
    replacementNotice: RegistryReplacementNotice? = nil
  ) {
    self.id = id
    self.op = op
    self.identifier = identifier
    self.windowID = windowID
    self.kind = kind
    self.clientID = clientID
    self.clientClear = clientClear
    self.clientSnapshot = clientSnapshot
    self.replacementNotice = replacementNotice
  }
}

public struct RegistryErrorPayload: Sendable, Codable, Equatable {
  public var code: String
  public var message: String

  public init(code: String, message: String) {
    self.code = code
    self.message = message
  }
}

public enum RegistryResponse: Sendable {
  case success(id: Int, result: RegistryResult)
  case failure(id: Int, error: RegistryErrorPayload)
}

public enum RegistryResult: Sendable, Codable, Equatable {
  case ping(PingResult)
  case listWindows(ListWindowsResult)
  case listElements(ListElementsResult)
  case getElement(GetElementResult)
  case ack(RegistryAckResult)
}

public struct PingResult: Sendable, Codable, Equatable {
  public var protocolVersion: Int
  public var appVersion: String
  public var bundleIdentifier: String
  public var capabilities: [RegistryCapability]

  public init(
    protocolVersion: Int,
    appVersion: String,
    bundleIdentifier: String,
    capabilities: [RegistryCapability] = []
  ) {
    self.protocolVersion = protocolVersion
    self.appVersion = appVersion
    self.bundleIdentifier = bundleIdentifier
    self.capabilities = capabilities
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
    appVersion = try container.decode(String.self, forKey: .appVersion)
    bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
    capabilities =
      try container.decodeIfPresent([RegistryCapability].self, forKey: .capabilities) ?? []
  }

  private enum CodingKeys: String, CodingKey {
    case protocolVersion
    case appVersion
    case bundleIdentifier
    case capabilities
  }
}

public struct ListWindowsResult: Sendable, Codable, Equatable {
  public var windows: [RegistryWindow]
  public init(windows: [RegistryWindow]) { self.windows = windows }
}

public struct ListElementsResult: Sendable, Codable, Equatable {
  public var elements: [RegistryElement]
  public init(elements: [RegistryElement]) { self.elements = elements }
}

public struct GetElementResult: Sendable, Codable, Equatable {
  public var element: RegistryElement
  public init(element: RegistryElement) { self.element = element }
}

public struct RegistryAckResult: Sendable, Codable, Equatable {
  public var applied: Bool
  public var message: String?

  public init(applied: Bool, message: String? = nil) {
    self.applied = applied
    self.message = message
  }
}

public enum RegistryWireCodec {
  public static let maximumFrameBytes = registryMaximumFrameBytes

  public static func encodeResponse(_ response: RegistryResponse) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    switch response {
    case .success(let id, let result):
      let envelope = SuccessEnvelope(id: id, ok: true, result: result)
      return try encoder.encode(envelope)
    case .failure(let id, let error):
      let envelope = FailureEnvelope(id: id, ok: false, error: error)
      return try encoder.encode(envelope)
    }
  }

  public static func decodeRequest(_ data: Data) throws -> RegistryRequest {
    let decoder = JSONDecoder()
    return try decoder.decode(RegistryRequest.self, from: data)
  }

  private struct SuccessEnvelope: Codable {
    let id: Int
    let ok: Bool
    let result: RegistryResult

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(id, forKey: .id)
      try container.encode(ok, forKey: .ok)
      switch result {
      case .ping(let payload):
        try container.encode(payload, forKey: .result)
      case .listWindows(let payload):
        try container.encode(payload, forKey: .result)
      case .listElements(let payload):
        try container.encode(payload, forKey: .result)
      case .getElement(let payload):
        try container.encode(payload, forKey: .result)
      case .ack(let payload):
        try container.encode(payload, forKey: .result)
      }
    }

    private enum CodingKeys: String, CodingKey {
      case id
      case ok
      case result
    }
  }

  private struct FailureEnvelope: Codable {
    let id: Int
    let ok: Bool
    let error: RegistryErrorPayload
  }
}

public enum RegistryWireCodecError: Error, CustomStringConvertible, LocalizedError {
  case frameTooLarge(maxBytes: Int)

  public var description: String {
    switch self {
    case .frameTooLarge(let maxBytes):
      "registry frame exceeded the \(maxBytes)-byte limit"
    }
  }

  public var errorDescription: String? {
    description
  }
}

/// Splits a sliding byte buffer into complete NDJSON lines.
///
/// Kept public so the registry host, socket client, and tests share one
/// framing implementation.
public struct NDJSONLineBuffer {
  private var buffer: Data = Data()

  public init() {}

  public mutating func append(_ data: Data) -> [Data] {
    (try? append(data, maxBufferedBytes: registryMaximumFrameBytes)) ?? []
  }

  public mutating func append(_ data: Data, maxBufferedBytes: Int) throws -> [Data] {
    buffer.append(data)
    if buffer.count > maxBufferedBytes {
      throw RegistryWireCodecError.frameTooLarge(maxBytes: maxBufferedBytes)
    }
    var lines: [Data] = []
    while let newlineIndex = buffer.firstIndex(of: 0x0A) {
      let range = buffer.startIndex..<newlineIndex
      let line = buffer.subdata(in: range)
      buffer.removeSubrange(buffer.startIndex...newlineIndex)
      if line.isEmpty == false {
        lines.append(line)
      }
    }
    return lines
  }

  public var pendingByteCount: Int { buffer.count }

  public mutating func drainPendingBytes() -> Data? {
    guard buffer.isEmpty == false else {
      return nil
    }
    defer { buffer.removeAll(keepingCapacity: false) }
    return buffer
  }
}
