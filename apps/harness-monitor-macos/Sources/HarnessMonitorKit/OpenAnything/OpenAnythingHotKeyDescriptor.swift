import Foundation

#if canImport(Carbon)
  import Carbon
#endif

/// Bit flags for the global hot key modifier set.
///
/// The raw value is a `UInt8`: only the low 8 bits are persisted. Adding more
/// than 8 modifier cases would silently truncate during storage round-trip
/// (`storageValue` → `init?(storageValue:)`). If a future change needs more
/// than 8 modifier bits, widen `rawValue` to `UInt16`/`UInt32` and bump the
/// storage format with explicit version handling.
public struct OpenAnythingHotKeyModifiers: OptionSet, Codable, Hashable, Sendable {
  public let rawValue: UInt8

  public init(rawValue: UInt8) {
    self.rawValue = rawValue
  }

  /// Maximum number of distinct modifier bits the storage format can carry.
  ///
  /// Encoded into the descriptor via `UInt8` so `rawValue` cannot exceed 8 bits.
  /// Callers adding a new modifier case must keep the total at or below this
  /// capacity and update the storage format if more bits are needed.
  public static let bitCapacity: Int = 8

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

  #if canImport(Carbon)
    /// Carbon modifier flags (`controlKey`, `optionKey`, `cmdKey`, `shiftKey`)
    /// folded into a single `UInt32` for `RegisterEventHotKey`. Lives kit-side
    /// so it is unit-testable; the Carbon wrapper in the app target consumes it
    /// directly.
    public var carbonFlags: UInt32 {
      var flags: UInt32 = 0
      if contains(.control) { flags |= UInt32(controlKey) }
      if contains(.option) { flags |= UInt32(optionKey) }
      if contains(.command) { flags |= UInt32(cmdKey) }
      if contains(.shift) { flags |= UInt32(shiftKey) }
      return flags
    }
  #endif
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
    guard let rawValue else {
      return defaultValue
    }
    guard let descriptor = Self(storageValue: rawValue), descriptor.isValid else {
      HarnessMonitorLogger.store.warning(
        "OpenAnything hot key descriptor decode failed; reset to default (raw=\(rawValue, privacy: .public))"
      )
      return defaultValue
    }
    return descriptor
  }

  public init?(storageValue: String) {
    // `maxSplits: 2` caps the split at three components so a `key` containing
    // a literal `|` (e.g. typed as the shortcut key) does not break the round
    // trip. The keyCode and modifier components never contain `|`, so they
    // remain the first two slots.
    let parts = storageValue.split(
      separator: "|",
      maxSplits: 2,
      omittingEmptySubsequences: false
    )
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
