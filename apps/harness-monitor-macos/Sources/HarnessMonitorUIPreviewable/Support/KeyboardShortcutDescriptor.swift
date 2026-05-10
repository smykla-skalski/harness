import SwiftUI

enum KeyboardShortcutModifierToken: Equatable {
  case command
  case option
  case control
  case shift

  var symbol: String {
    switch self {
    case .command: "⌘"
    case .option: "⌥"
    case .control: "⌃"
    case .shift: "⇧"
    }
  }

  var eventModifier: EventModifiers {
    switch self {
    case .command: .command
    case .option: .option
    case .control: .control
    case .shift: .shift
    }
  }
}

enum KeyboardShortcutDisplayPart: Equatable {
  case modifier(KeyboardShortcutModifierToken)
  case key(String)

  var text: String {
    switch self {
    case .modifier(let modifier):
      modifier.symbol
    case .key(let key):
      key
    }
  }

  func isHighlighted(with activeModifiers: EventModifiers) -> Bool {
    guard case .modifier(let modifier) = self else {
      return false
    }
    return activeModifiers.contains(modifier.eventModifier)
  }
}

public struct KeyboardShortcutDescriptor: Equatable {
  let modifiers: [KeyboardShortcutModifierToken]
  let keyLabel: String
  public let keyEquivalent: KeyEquivalent

  init(
    modifiers: [KeyboardShortcutModifierToken],
    keyEquivalent: KeyEquivalent,
    keyLabel: String
  ) {
    self.modifiers = modifiers
    self.keyEquivalent = keyEquivalent
    self.keyLabel = keyLabel
  }

  public var hint: String {
    modifiers.map(\.symbol).joined() + keyLabel
  }

  public var requiredEventModifiers: EventModifiers {
    modifiers.reduce(into: EventModifiers()) { partialResult, modifier in
      partialResult.insert(modifier.eventModifier)
    }
  }

  public func isRevealed(by activeModifiers: EventModifiers) -> Bool {
    !activeModifiers.intersection(requiredEventModifiers).isEmpty
  }

  var displayParts: [KeyboardShortcutDisplayPart] {
    modifiers.map(KeyboardShortcutDisplayPart.modifier) + [.key(keyLabel)]
  }
}

enum KeyboardShortcutRevealPolicy: Equatable {
  case alwaysVisible
  case revealOnRelevantModifierHold
}
