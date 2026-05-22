import Foundation

public struct OpenAnythingHotKeyModifiers: OptionSet, Codable, Hashable, Sendable {
  public let rawValue: UInt8

  public init(rawValue: UInt8) {
    self.rawValue = rawValue
  }

  public static let control = Self(rawValue: 1 << 0)
  public static let option = Self(rawValue: 1 << 1)
  public static let command = Self(rawValue: 1 << 2)
  public static let shift = Self(rawValue: 1 << 3)

  public var displayText: String {
    var parts: [String] = []
    if contains(.control) { parts.append("⌃") }
    if contains(.option) { parts.append("⌥") }
    if contains(.shift) { parts.append("⇧") }
    if contains(.command) { parts.append("⌘") }
    return parts.joined()
  }

  public var hasPrimaryModifier: Bool {
    contains(.control) || contains(.option) || contains(.command)
  }
}

public struct OpenAnythingHotKeyDescriptor: Codable, Hashable, Sendable {
  public let keyCode: UInt32
  public let key: String
  public let modifiers: OpenAnythingHotKeyModifiers

  public init(
    keyCode: UInt32,
    key: String,
    modifiers: OpenAnythingHotKeyModifiers
  ) {
    self.keyCode = keyCode
    self.key = key
    self.modifiers = modifiers
  }

  public static let defaultValue = Self(
    keyCode: 49,
    key: "Space",
    modifiers: [.control, .option]
  )

  public var displayText: String {
    modifiers.displayText + key
  }

  public var isValid: Bool {
    keyCode > 0
      && !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && modifiers.hasPrimaryModifier
  }

  public var storageValue: String {
    "\(keyCode)|\(modifiers.rawValue)|\(key)"
  }

  public static func decode(_ rawValue: String?) -> Self {
    guard
      let rawValue,
      let descriptor = Self(storageValue: rawValue),
      descriptor.isValid
    else {
      return defaultValue
    }
    return descriptor
  }

  public init?(storageValue: String) {
    let parts = storageValue.split(separator: "|", omittingEmptySubsequences: false)
    guard parts.count == 3, let keyCode = UInt32(parts[0]), let modifiersRaw = UInt8(parts[1])
    else {
      return nil
    }
    self.init(
      keyCode: keyCode,
      key: String(parts[2]),
      modifiers: OpenAnythingHotKeyModifiers(rawValue: modifiersRaw)
    )
  }
}

public enum OpenAnythingHotKeyDefaults {
  public static let enabledKey = "harness.openAnything.globalHotKey.enabled"
  public static let descriptorKey = "harness.openAnything.globalHotKey.descriptor"
  public static let enabledDefault = false
  public static let descriptorDefault = OpenAnythingHotKeyDescriptor.defaultValue
}
