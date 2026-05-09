import HarnessMonitorKit
import SwiftUI

struct SessionWindowCreateFormCodexFields: View {
  @Binding var mode: CodexRunMode
  @Binding var model: String
  @Binding var effort: String
  @Binding var allowCustomModel: Bool

  var body: some View {
    Section("Codex Run") {
      Picker("Mode", selection: $mode) {
        ForEach(CodexRunMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .accessibilityLabel("Codex mode")

      TextField("Model (optional)", text: $model)
        .scaledFont(.body)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("Codex model")

      TextField("Effort (optional)", text: $effort)
        .scaledFont(.body)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("Codex effort")

      Toggle("Allow custom model", isOn: $allowCustomModel)
        .accessibilityLabel("Allow custom Codex model")
    }
  }
}

struct SessionWindowCreateFormAgentLaunchToggle: View {
  @Binding var useCodex: Bool

  var body: some View {
    Section {
      Picker("Launch", selection: $useCodex) {
        Text("Terminal").tag(false)
        Text("Codex").tag(true)
      }
      .pickerStyle(.segmented)
      .accessibilityLabel("Agent launch kind")
    }
  }
}
