import Foundation

/// Severity of a global hot key conflict with system or in-app shortcuts.
///
/// Used by the hot key recorder (Unit 6) to flag risky chords before they are
/// committed to the descriptor store. `hard` chords would prevent the system
/// from delivering critical Mac shortcuts (e.g. Spotlight, Quit) and should be
/// refused outright. `soft` chords collide with common in-app shortcuts; the
/// recorder warns but still allows the user to proceed.
public enum OpenAnythingHotKeyConflictSeverity: Sendable, Hashable {
  case hard
  case soft
  case none
}

/// Pure evaluator: maps a descriptor onto a conflict severity. No state, no
/// side effects, so the recorder can call it on every keystroke.
public enum OpenAnythingHotKeyConflicts {
  /// Carbon keyCodes for keys that participate in known conflicting chords.
  /// Values match `Carbon/Events.h` virtual key codes. Listed inline so this
  /// file stays a pure logic layer with no Carbon dependency.
  enum KeyCode {
    static let space: UInt32 = 49
    static let q: UInt32 = 12
    static let w: UInt32 = 13
    static let tab: UInt32 = 48
    static let k: UInt32 = 40
    static let f: UInt32 = 3
    static let p: UInt32 = 35
    static let t: UInt32 = 17
    static let s: UInt32 = 1
    static let n: UInt32 = 45
    static let o: UInt32 = 31
    static let z: UInt32 = 6
  }

  /// Returns the conflict severity for the supplied descriptor.
  ///
  /// Hard-blocked chords (would break the system if Open Anything claimed them):
  /// - `Cmd+Space` — Spotlight
  /// - `Cmd+Q` — Quit application
  /// - `Cmd+W` — Close window
  /// - `Cmd+Tab` — App switcher
  ///
  /// Soft-warning chords (conflict with in-app shortcuts but the system keeps
  /// working):
  /// - `Cmd+K` — palette itself, would shadow Open Anything's own menu command
  /// - `Cmd+F` — find
  /// - `Cmd+P` — print / find files
  /// - `Cmd+T` — new tab
  /// - `Cmd+S` — save
  /// - `Cmd+N` — new
  /// - `Cmd+O` — open
  /// - `Cmd+Z` — undo
  ///
  /// All other chords return `.none`.
  public static func evaluate(
    _ descriptor: OpenAnythingHotKeyDescriptor
  ) -> OpenAnythingHotKeyConflictSeverity {
    if matchesHardChord(descriptor) { return .hard }
    if matchesSoftChord(descriptor) { return .soft }
    return .none
  }

  // MARK: - Hard list

  private static func matchesHardChord(
    _ descriptor: OpenAnythingHotKeyDescriptor
  ) -> Bool {
    let isCommandOnly = descriptor.modifiers == [.command]
    guard isCommandOnly else { return false }
    switch descriptor.keyCode {
    case KeyCode.space, KeyCode.q, KeyCode.w, KeyCode.tab:
      return true
    default:
      return false
    }
  }

  // MARK: - Soft list

  private static func matchesSoftChord(
    _ descriptor: OpenAnythingHotKeyDescriptor
  ) -> Bool {
    let isCommandOnly = descriptor.modifiers == [.command]
    guard isCommandOnly else { return false }
    switch descriptor.keyCode {
    case
      KeyCode.k,
      KeyCode.f,
      KeyCode.p,
      KeyCode.t,
      KeyCode.s,
      KeyCode.n,
      KeyCode.o,
      KeyCode.z:
      return true
    default:
      return false
    }
  }
}
