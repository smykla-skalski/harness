import CoreGraphics
import Foundation

public let registryProtocolVersion: Int = 1
public let registryMaximumFrameBytes: Int = 1 << 20
/// Keep short - Unix domain sockets have a 104-byte path limit on macOS.
public let registrySocketFilename: String = "mcp.sock"
public let registryAppGroupIdentifier: String = "Q498EB36N4.io.harnessmonitor"

public enum RegistryCapability: String, Sendable, Codable, CaseIterable {
  case clientSnapshots = "client-snapshots"
  case clientSnapshotLeases = "client-snapshot-leases"
  case replacementNotice = "replacement-notice"
  case semanticActions = "semantic-actions"
}

public enum RegistryElementKind: String, Sendable, Codable, CaseIterable {
  case button
  case toggle
  case textField
  case text
  case link
  case list
  case row
  case tab
  case menuItem
  case image
  case other
}

public enum RegistrySemanticAction: String, Sendable, Codable, CaseIterable {
  case press
}

public struct RegistryRect: Sendable, Codable, Equatable {
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  public init(_ rect: CGRect) {
    self.x = Double(rect.origin.x)
    self.y = Double(rect.origin.y)
    self.width = Double(rect.size.width)
    self.height = Double(rect.size.height)
  }

  public var cgRect: CGRect {
    CGRect(x: x, y: y, width: width, height: height)
  }
}

public struct RegistryElement: Sendable, Codable, Equatable {
  public var identifier: String
  public var label: String?
  public var value: String?
  public var hint: String?
  public var kind: RegistryElementKind
  public var actions: [RegistrySemanticAction]
  public var frame: RegistryRect
  public var windowID: Int?
  public var enabled: Bool
  public var selected: Bool
  public var focused: Bool

  public init(
    identifier: String,
    label: String? = nil,
    value: String? = nil,
    hint: String? = nil,
    kind: RegistryElementKind,
    actions: [RegistrySemanticAction] = [],
    frame: RegistryRect,
    windowID: Int? = nil,
    enabled: Bool = true,
    selected: Bool = false,
    focused: Bool = false
  ) {
    self.identifier = identifier
    self.label = label
    self.value = value
    self.hint = hint
    self.kind = kind
    self.actions = actions
    self.frame = frame
    self.windowID = windowID
    self.enabled = enabled
    self.selected = selected
    self.focused = focused
  }
}

public struct RegistryWindow: Sendable, Codable, Equatable {
  public var id: Int
  public var title: String
  public var role: String?
  public var frame: RegistryRect
  public var isKey: Bool
  public var isMain: Bool

  public init(
    id: Int,
    title: String,
    role: String? = nil,
    frame: RegistryRect,
    isKey: Bool = false,
    isMain: Bool = false
  ) {
    self.id = id
    self.title = title
    self.role = role
    self.frame = frame
    self.isKey = isKey
    self.isMain = isMain
  }
}

public struct RegistryClientSnapshot: Sendable, Codable, Equatable {
  public var clientID: UUID
  public var generation: UInt64
  public var appVersion: String
  public var bundleIdentifier: String
  public var snapshot: RegistrySnapshot

  public init(
    clientID: UUID,
    generation: UInt64 = 0,
    appVersion: String,
    bundleIdentifier: String,
    snapshot: RegistrySnapshot
  ) {
    self.clientID = clientID
    self.generation = generation
    self.appVersion = appVersion
    self.bundleIdentifier = bundleIdentifier
    self.snapshot = snapshot
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    clientID = try container.decode(UUID.self, forKey: .clientID)
    generation = try container.decodeIfPresent(UInt64.self, forKey: .generation) ?? 0
    appVersion = try container.decode(String.self, forKey: .appVersion)
    bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
    snapshot = try container.decode(RegistrySnapshot.self, forKey: .snapshot)
  }

  private enum CodingKeys: String, CodingKey {
    case clientID
    case generation
    case appVersion
    case bundleIdentifier
    case snapshot
  }
}

public struct RegistryClientClearRequest: Sendable, Codable, Equatable {
  public var clientID: UUID
  public var generation: UInt64

  public init(clientID: UUID, generation: UInt64) {
    self.clientID = clientID
    self.generation = generation
  }
}

public struct RegistryReplacementNotice: Sendable, Codable, Equatable {
  public var socketPath: String
  public var protocolVersion: Int
  public var appVersion: String
  public var bundleIdentifier: String
  public var message: String

  public init(
    socketPath: String,
    protocolVersion: Int,
    appVersion: String,
    bundleIdentifier: String,
    message: String
  ) {
    self.socketPath = socketPath
    self.protocolVersion = protocolVersion
    self.appVersion = appVersion
    self.bundleIdentifier = bundleIdentifier
    self.message = message
  }
}
