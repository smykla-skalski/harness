import AppKit
import HarnessMonitorKit
import SwiftUI

/// Visible recorder surface used by `OpenAnythingHotKeySettingsView`.
///
/// Replaces the prior 1x1 invisible NSView so VoiceOver users can reach the
/// recorder. The visible SwiftUI pill renders the prompt text and the
/// in-progress chord; an overlaid `OpenAnythingHotKeyRecorderRepresentable`
/// hosts the AppKit `NSView` that catches `keyDown` events. The representable
/// uses `.allowsHitTesting(true)` so clicks reach it through the pill chrome.
///
/// Callback contract:
/// - `onRecord` fires only for a valid chord (primary modifier + key) - the
///   NSView ignores raw keystrokes that lack Control/Option/Command so the
///   user can keep trying without exiting recording mode.
/// - `onCancel` fires when Escape is pressed; the parent restores the prior
///   descriptor.
/// - `onClear` fires when Delete or Forward Delete is pressed; the parent
///   resets the descriptor to its default.
struct OpenAnythingHotKeyRecorderPill: View {
  let currentDescriptor: OpenAnythingHotKeyDescriptor
  let onRecord: (OpenAnythingHotKeyDescriptor) -> Void
  let onCancel: () -> Void
  let onClear: () -> Void

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: "keyboard")
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .imageScale(.small)

      VStack(alignment: .leading, spacing: 2) {
        Text("Type a shortcut\u{2026}")
          .font(.callout.weight(.medium))
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        Text("Press \u{238B} to cancel, \u{232B} to clear")
          .font(.caption2)
          .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
      }

      Spacer(minLength: 0)
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingMD)
    .padding(.vertical, HarnessMonitorTheme.spacingSM)
    .frame(maxWidth: .infinity, alignment: .leading)
    .harnessFloatingControlGlass(
      cornerRadius: HarnessMonitorTheme.cornerRadiusSM,
      prominence: .subdued
    )
    .overlay {
      OpenAnythingHotKeyRecorderRepresentable(
        onRecord: onRecord,
        onCancel: onCancel,
        onClear: onClear
      )
      .allowsHitTesting(true)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "Recording shortcut. Press a key combination. "
        + "Press Escape to cancel, Delete to clear."
    )
    .accessibilityValue(Text(currentDescriptor.spokenDescription))
  }
}

/// SwiftUI representable that hosts the AppKit key-event sink under the
/// visible pill. `makeFirstResponder` runs in `makeNSView` only; subsequent
/// state changes do not re-focus the view, eliminating the recorder focus
/// blink.
struct OpenAnythingHotKeyRecorderRepresentable: NSViewRepresentable {
  let onRecord: (OpenAnythingHotKeyDescriptor) -> Void
  let onCancel: () -> Void
  let onClear: () -> Void

  func makeNSView(context: Context) -> OpenAnythingHotKeyRecorderNSView {
    let view = OpenAnythingHotKeyRecorderNSView(
      onRecord: onRecord,
      onCancel: onCancel,
      onClear: onClear
    )
    DispatchQueue.main.async { [weak view] in
      view?.window?.makeFirstResponder(view)
    }
    return view
  }

  func updateNSView(_ nsView: OpenAnythingHotKeyRecorderNSView, context: Context) {
    // Refresh callbacks only; never re-issue makeFirstResponder here,
    // otherwise the recorder steals focus on every recorded keystroke and the
    // pill chrome appears to blink.
    nsView.onRecord = onRecord
    nsView.onCancel = onCancel
    nsView.onClear = onClear
  }
}

final class OpenAnythingHotKeyRecorderNSView: NSView {
  var onRecord: (OpenAnythingHotKeyDescriptor) -> Void
  var onCancel: () -> Void
  var onClear: () -> Void

  init(
    onRecord: @escaping (OpenAnythingHotKeyDescriptor) -> Void,
    onCancel: @escaping () -> Void,
    onClear: @escaping () -> Void
  ) {
    self.onRecord = onRecord
    self.onCancel = onCancel
    self.onClear = onClear
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override var acceptsFirstResponder: Bool { true }

  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case Self.escapeKeyCode:
      onCancel()
    case Self.deleteKeyCode, Self.forwardDeleteKeyCode:
      onClear()
    default:
      let descriptor = Self.descriptor(from: event)
      // Ignore raw key presses without a primary modifier so the user can keep
      // typing until a valid chord is held. The recorder stays armed and no
      // validation error appears.
      guard descriptor.modifiers.hasPrimaryModifier else { return }
      onRecord(descriptor)
    }
  }

  // MARK: - Carbon virtual key codes for control keys

  private static let escapeKeyCode: UInt16 = 53
  private static let deleteKeyCode: UInt16 = 51
  private static let forwardDeleteKeyCode: UInt16 = 117
  private static let spaceKeyCode: UInt16 = 49

  private static func descriptor(from event: NSEvent) -> OpenAnythingHotKeyDescriptor {
    OpenAnythingHotKeyDescriptor(
      keyCode: UInt32(event.keyCode),
      key: displayKey(for: event),
      modifiers: OpenAnythingHotKeyModifiers(nsFlags: event.modifierFlags)
    )
  }

  private static func displayKey(for event: NSEvent) -> String {
    if event.keyCode == spaceKeyCode {
      return "Space"
    }
    let rawKey = event.charactersIgnoringModifiers ?? ""
    let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Key \(event.keyCode)" : trimmed.uppercased()
  }
}

extension OpenAnythingHotKeyModifiers {
  init(nsFlags: NSEvent.ModifierFlags) {
    var modifiers: OpenAnythingHotKeyModifiers = []
    if nsFlags.contains(.control) { modifiers.insert(.control) }
    if nsFlags.contains(.option) { modifiers.insert(.option) }
    if nsFlags.contains(.command) { modifiers.insert(.command) }
    if nsFlags.contains(.shift) { modifiers.insert(.shift) }
    self = modifiers
  }
}

extension OpenAnythingHotKeyDescriptor {
  /// VoiceOver-friendly rendering of the descriptor. Replaces the symbolic
  /// `\u{2303}\u{2325}Space` form with words VoiceOver can pronounce. Scoped
  /// to the UI layer because kit-side consumers do not need spoken text; they
  /// render the symbolic form directly.
  var spokenDescription: String {
    var parts: [String] = []
    if modifiers.contains(.control) { parts.append("Control") }
    if modifiers.contains(.option) { parts.append("Option") }
    if modifiers.contains(.shift) { parts.append("Shift") }
    if modifiers.contains(.command) { parts.append("Command") }
    let keyLabel = key.isEmpty ? "Key \(keyCode)" : key
    parts.append(keyLabel)
    return parts.joined(separator: " ")
  }
}
