import HarnessMonitorKit
import SwiftUI

struct SettingsSecretField: View {
  let title: String
  let placeholder: String
  @Binding var field: TaskBoardSecretField
  let accessibilityIdentifier: String

  @State private var draft: String = ""
  @State private var isRevealed = false

  var body: some View {
    HStack(spacing: 6) {
      switch field {
      case .configured:
        configuredRow
      case .notConfigured:
        editingRow
          .onAppear { sync(from: field) }
      case .editing:
        editingRow
      }
    }
    .onChange(of: field) { _, newValue in
      sync(from: newValue)
    }
    .onDisappear {
      bestEffortZero(&draft)
      if case .editing(var value) = field {
        bestEffortZero(&value)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(title)
  }

  private var configuredRow: some View {
    HStack(spacing: 6) {
      Text(title)
      Spacer(minLength: 0)
      Text("Configured")
        .font(.caption)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
          Capsule().fill(HarnessMonitorTheme.accent.opacity(0.18))
        )
        .accessibilityIdentifier(accessibilityIdentifier + ".configured-pill")
      Button("Replace…") {
        field = .editing("")
        draft = ""
      }
      .buttonStyle(.borderless)
      .accessibilityIdentifier(accessibilityIdentifier + ".replace-button")
      Button(role: .destructive) {
        field = .notConfigured
        draft = ""
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(.borderless)
      .help("Clear stored value")
      .accessibilityLabel("Clear \(title)")
      .accessibilityIdentifier(accessibilityIdentifier + ".clear-button")
    }
  }

  private var editingRow: some View {
    HStack(spacing: 6) {
      Group {
        if isRevealed {
          TextField(placeholder, text: editingBinding)
            .textContentType(.password)
        } else {
          SecureField(placeholder, text: editingBinding)
            .textContentType(.password)
        }
      }
      .accessibilityLabel(title)
      .accessibilityIdentifier(accessibilityIdentifier)
      .privacySensitive(true)

      Button {
        isRevealed.toggle()
      } label: {
        Image(systemName: isRevealed ? "eye.slash" : "eye")
          .imageScale(.medium)
      }
      .buttonStyle(.borderless)
      .accessibilityLabel(isRevealed ? "Hide \(title)" : "Reveal \(title)")
      .help(isRevealed ? "Hide value" : "Reveal value")
    }
  }

  private var editingBinding: Binding<String> {
    Binding(
      get: { draft },
      set: { value in
        draft = value
        if !value.isEmpty {
          field = .editing(value)
        } else if field.isEditing {
          field = .editing("")
        }
      }
    )
  }

  private func sync(from value: TaskBoardSecretField) {
    if case .editing(let payload) = value {
      if draft != payload {
        draft = payload
      }
    } else if !draft.isEmpty {
      bestEffortZero(&draft)
    }
  }

  private func bestEffortZero(_ value: inout String) {
    guard !value.isEmpty else { return }
    var data = Data(value.utf8)
    data.withUnsafeMutableBytes { buffer in
      for index in buffer.indices {
        buffer[index] = 0
      }
    }
    value = ""
  }
}
