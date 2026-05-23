import Testing

@testable import HarnessMonitorKit

@Suite("OpenAnything hot key conflict evaluator")
struct OpenAnythingHotKeyConflictsTests {
  // MARK: - Hard-blocked chords

  @Test("Cmd+Space is hard-blocked (Spotlight)")
  func cmdSpaceIsHard() {
    let descriptor = OpenAnythingHotKeyDescriptor(
      keyCode: 49,
      key: "Space",
      modifiers: [.command]
    )
    #expect(OpenAnythingHotKeyConflicts.evaluate(descriptor) == .hard)
  }

  @Test("Cmd+Q is hard-blocked (Quit)")
  func cmdQIsHard() {
    let descriptor = OpenAnythingHotKeyDescriptor(
      keyCode: 12,
      key: "Q",
      modifiers: [.command]
    )
    #expect(OpenAnythingHotKeyConflicts.evaluate(descriptor) == .hard)
  }

  @Test("Cmd+W is hard-blocked (Close Window)")
  func cmdWIsHard() {
    let descriptor = OpenAnythingHotKeyDescriptor(
      keyCode: 13,
      key: "W",
      modifiers: [.command]
    )
    #expect(OpenAnythingHotKeyConflicts.evaluate(descriptor) == .hard)
  }

  @Test("Cmd+Tab is hard-blocked (App Switcher)")
  func cmdTabIsHard() {
    let descriptor = OpenAnythingHotKeyDescriptor(
      keyCode: 48,
      key: "Tab",
      modifiers: [.command]
    )
    #expect(OpenAnythingHotKeyConflicts.evaluate(descriptor) == .hard)
  }

  // MARK: - Soft-warning chords

  @Test("Cmd+K is soft (palette itself)")
  func cmdKIsSoft() {
    let descriptor = OpenAnythingHotKeyDescriptor(
      keyCode: 40,
      key: "K",
      modifiers: [.command]
    )
    #expect(OpenAnythingHotKeyConflicts.evaluate(descriptor) == .soft)
  }

  @Test("Cmd+F is soft (find)")
  func cmdFIsSoft() {
    let descriptor = OpenAnythingHotKeyDescriptor(
      keyCode: 3,
      key: "F",
      modifiers: [.command]
    )
    #expect(OpenAnythingHotKeyConflicts.evaluate(descriptor) == .soft)
  }

  @Test("Common Command-only single-letter chords are soft")
  func commonCommandLetterChordsAreSoft() {
    let chords: [(UInt32, String)] = [
      (35, "P"),
      (17, "T"),
      (1, "S"),
      (45, "N"),
      (31, "O"),
      (6, "Z")
    ]
    for (keyCode, key) in chords {
      let descriptor = OpenAnythingHotKeyDescriptor(
        keyCode: keyCode,
        key: key,
        modifiers: [.command]
      )
      #expect(
        OpenAnythingHotKeyConflicts.evaluate(descriptor) == .soft,
        "Expected \(key) to map to .soft"
      )
    }
  }

  // MARK: - Non-conflicting chords

  @Test("Cmd+Shift+P is unconflicted (uncommon chord)")
  func cmdShiftPIsNone() {
    let descriptor = OpenAnythingHotKeyDescriptor(
      keyCode: 35,
      key: "P",
      modifiers: [.command, .shift]
    )
    #expect(OpenAnythingHotKeyConflicts.evaluate(descriptor) == .none)
  }

  @Test("Default Control+Option+Space is unconflicted")
  func defaultDescriptorIsNone() {
    #expect(OpenAnythingHotKeyConflicts.evaluate(.defaultValue) == .none)
  }

  @Test("Cmd+Shift+K is unconflicted (scoped variant)")
  func cmdShiftKIsNone() {
    let descriptor = OpenAnythingHotKeyDescriptor(
      keyCode: 40,
      key: "K",
      modifiers: [.command, .shift]
    )
    #expect(OpenAnythingHotKeyConflicts.evaluate(descriptor) == .none)
  }

  @Test("Control+K is unconflicted (no Command modifier)")
  func controlKIsNone() {
    let descriptor = OpenAnythingHotKeyDescriptor(
      keyCode: 40,
      key: "K",
      modifiers: [.control]
    )
    #expect(OpenAnythingHotKeyConflicts.evaluate(descriptor) == .none)
  }

  @Test("Cmd+Space with extra modifiers is unconflicted")
  func cmdShiftSpaceIsNone() {
    // Cmd+Shift+Space is not Spotlight; only bare Cmd+Space is.
    let descriptor = OpenAnythingHotKeyDescriptor(
      keyCode: 49,
      key: "Space",
      modifiers: [.command, .shift]
    )
    #expect(OpenAnythingHotKeyConflicts.evaluate(descriptor) == .none)
  }
}
