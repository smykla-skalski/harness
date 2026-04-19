import Foundation

public enum RegistryRequestOp: String, Sendable, Codable {
  case ping
  case listWindows
  case listElements
  case getElement
}

public struct RegistryRequest: Sendable, Codable {
  public var id: Int
  public var op: RegistryRequestOp
  public var identifier: String?
  public var windowID: Int?
  public var kind: RegistryElementKind?

  public init(
    id: Int,
    op: RegistryRequestOp,
    identifier: String? = nil,
    windowID: Int? = nil,
    kind: RegistryElementKind? = nil
  ) {
    self.id = id
    self.op = op
    self.identifier = identifier
    self.windowID = windowID
    self.kind = kind
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
}

public struct PingResult: Sendable, Codable, Equatable {
  public var protocolVersion: Int
  public var appVersion: String
  public var bundleIdentifier: String

  public init(protocolVersion: Int, appVersion: String, bundleIdentifier: String) {
    self.protocolVersion = protocolVersion
    self.appVersion = appVersion
    self.bundleIdentifier = bundleIdentifier
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

public enum RegistryWireCodec {
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
