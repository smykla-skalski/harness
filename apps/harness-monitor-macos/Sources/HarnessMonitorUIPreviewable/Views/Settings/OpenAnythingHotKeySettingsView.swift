import AppKit
import HarnessMonitorKit
import SwiftUI

struct OpenAnythingHotKeySettingsView: View {
  @Binding var isEnabled: Bool
  @Binding var descriptorStorage: String
  @State private var isRecording = false
  @State private var validationMessage: String?

  private var descriptor: OpenAnythingHotKeyDescriptor {
    OpenAnythingHotKeyDescriptor.decode(descriptorStorage)
  }

  var body: some View {
    Toggle("Enable global Open Anything hotkey", isOn: $isEnabled)
      .accessibilityIdentifier(HarnessMonitorAccessibility.openAnythingGlobalHotKeyToggle)

    HStack {
      LabeledContent("Global hotkey") {
        Text(descriptor.displayText)
          .monospaced()
      }

      Button(isRecording ? "Press Shortcut" : "Record…") {
        validationMessage = nil
        isRecording.toggle()
      }
      .accessibilityIdentifier(HarnessMonitorAccessibility.openAnythingGlobalHotKeyRecordButton)

      Button("Reset") {
        validationMessage = nil
        descriptorStorage = OpenAnythingHotKeyDescriptor.defaultValue.storageValue
      }
      .accessibilityIdentifier(HarnessMonitorAccessibility.openAnythingGlobalHotKeyResetButton)
    }

    if isRecording {
      OpenAnythingHotKeyRecorder { descriptor in
        if descriptor.isValid {
          descriptorStorage = descriptor.storageValue
          validationMessage = nil
        } else {
          validationMessage = "Use at least Control, Option, or Command with a key"
        }
        isRecording = false
      }
      .frame(width: 1, height: 1)
      .accessibilityHidden(true)
    }

    if let validationMessage {
      Text(validationMessage)
        .font(.caption)
        .foregroundStyle(.red)
    }
  }
}

private struct OpenAnythingHotKeyRecorder: NSViewRepresentable {
  let onRecord: (OpenAnythingHotKeyDescriptor) -> Void

  func makeNSView(context: Context) -> OpenAnythingHotKeyRecorderNSView {
    let view = OpenAnythingHotKeyRecorderNSView(onRecord: onRecord)
    DispatchQueue.main.async {
      view.window?.makeFirstResponder(view)
    }
    return view
  }

  func updateNSView(_ nsView: OpenAnythingHotKeyRecorderNSView, context: Context) {
    nsView.onRecord = onRecord
    DispatchQueue.main.async {
      nsView.window?.makeFirstResponder(nsView)
    }
  }
}

private final class OpenAnythingHotKeyRecorderNSView: NSView {
  var onRecord: (OpenAnythingHotKeyDescriptor) -> Void

  init(onRecord: @escaping (OpenAnythingHotKeyDescriptor) -> Void) {
    self.onRecord = onRecord
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override var acceptsFirstResponder: Bool { true }

  override func keyDown(with event: NSEvent) {
    onRecord(Self.descriptor(from: event))
  }

  private static func descriptor(from event: NSEvent) -> OpenAnythingHotKeyDescriptor {
    OpenAnythingHotKeyDescriptor(
      keyCode: UInt32(event.keyCode),
      key: displayKey(for: event),
      modifiers: OpenAnythingHotKeyModifiers(nsFlags: event.modifierFlags)
    )
  }

  private static func displayKey(for event: NSEvent) -> String {
    if event.keyCode == 49 {
      return "Space"
    }
    let rawKey = event.charactersIgnoringModifiers ?? ""
    let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Key \(event.keyCode)" : trimmed.uppercased()
  }
}

extension OpenAnythingHotKeyModifiers {
  fileprivate init(nsFlags: NSEvent.ModifierFlags) {
    var modifiers: OpenAnythingHotKeyModifiers = []
    if nsFlags.contains(.control) { modifiers.insert(.control) }
    if nsFlags.contains(.option) { modifiers.insert(.option) }
    if nsFlags.contains(.command) { modifiers.insert(.command) }
    if nsFlags.contains(.shift) { modifiers.insert(.shift) }
    self = modifiers
  }
}
