import CoreGraphics
import Foundation

public let registryProtocolVersion: Int = 1
public let registrySocketFilename: String = "harness-monitor-mcp.sock"
public let registryAppGroupIdentifier: String = "Q498EB36N4.io.harnessmonitor"

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
