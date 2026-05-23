import AppKit
import HarnessMonitorKit
import SwiftUI

struct OpenAnythingHotKeySettingsView: View {
  @Binding var isEnabled: Bool
  @Binding var descriptorStorage: String
  @State private var isRecording = false
  @State private var conflictSeverity: OpenAnythingHotKeyConflictSeverity = .none
  @State private var conflictMessage: String?

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
          .accessibilityLabel(descriptor.spokenDescription)
      }

      Button(isRecording ? "Press Shortcut" : "Record\u{2026}") {
        startOrStopRecording()
      }
      .accessibilityIdentifier(HarnessMonitorAccessibility.openAnythingGlobalHotKeyRecordButton)

      // Reset restores the descriptor only - it intentionally does NOT toggle
      // `isEnabled` off (audit #19). A user who hits Reset while the global
      // hotkey is on keeps it on with the default chord.
      Button("Reset") {
        clearConflictState()
        descriptorStorage = OpenAnythingHotKeyDescriptor.defaultValue.storageValue
      }
      .accessibilityIdentifier(HarnessMonitorAccessibility.openAnythingGlobalHotKeyResetButton)
    }

    if isRecording {
      OpenAnythingHotKeyRecorderPill(
        currentDescriptor: descriptor,
        onRecord: handleRecord(_:),
        onCancel: handleCancel,
        onClear: handleClear
      )
    }

    if let conflictMessage {
      conflictBanner(message: conflictMessage, severity: conflictSeverity)
    }
  }

  private func startOrStopRecording() {
    clearConflictState()
    isRecording.toggle()
  }

  private func handleRecord(_ descriptor: OpenAnythingHotKeyDescriptor) {
    guard descriptor.isValid else { return }
    let severity = OpenAnythingHotKeyConflicts.evaluate(descriptor)
    switch severity {
    case .hard:
      conflictSeverity = .hard
      conflictMessage = "This shortcut breaks a system feature - try a different one."
    // Hard chord: do not save, stay in recording so the user can pick another.
    case .soft:
      conflictSeverity = .soft
      conflictMessage =
        "This shortcut conflicts with an in-app feature. "
        + "Saved anyway, but expect overlap."
      descriptorStorage = descriptor.storageValue
      isRecording = false
    case .none:
      clearConflictState()
      descriptorStorage = descriptor.storageValue
      isRecording = false
    }
  }

  private func handleCancel() {
    clearConflictState()
    isRecording = false
  }

  private func handleClear() {
    clearConflictState()
    descriptorStorage = OpenAnythingHotKeyDescriptor.defaultValue.storageValue
    isRecording = false
  }

  private func clearConflictState() {
    conflictSeverity = .none
    conflictMessage = nil
  }

  @ViewBuilder
  private func conflictBanner(
    message: String,
    severity: OpenAnythingHotKeyConflictSeverity
  ) -> some View {
    let color = severity == .hard ? HarnessMonitorTheme.danger : HarnessMonitorTheme.caution
    let icon = severity == .hard ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill"
    HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: icon)
        .foregroundStyle(color)
      Text(message)
        .font(.caption)
        .foregroundStyle(color)
    }
    .accessibilityElement(children: .combine)
  }
}
