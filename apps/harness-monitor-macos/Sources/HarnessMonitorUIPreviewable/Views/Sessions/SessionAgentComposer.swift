import HarnessMonitorKit
import SwiftUI

enum SessionAgentComposerField: Hashable {
  case composer
}

enum SessionAgentComposerKeyLayout {
  static let rows: [[AgentTuiKey]] = [
    [.escape, .tab, .enter, .backspace],
    [.arrowLeft, .arrowUp, .arrowDown, .arrowRight],
  ]

  static var flattened: [AgentTuiKey] {
    rows.flatMap(\.self)
  }
}

struct SessionAgentComposer: View {
  let agentID: String
  @Binding var message: String
  let focusedField: FocusState<SessionAgentComposerField?>.Binding
  @Binding var backdropHeight: CGFloat
  let metrics: SessionAgentDetailSectionMetrics
  let isActive: Bool
  let canSendInput: Bool
  let sendMessage: () -> Void
  let sendKey: (AgentTuiKey) -> Void

  var body: some View {
    HStack(alignment: .bottom, spacing: metrics.composerSpacing) {
      HarnessMonitorMultilineTextField(
        placeholder: "",
        text: $message,
        minHeight: metrics.composerMinHeight,
        maxHeight: metrics.composerMaxHeight,
        focusedField: focusedField,
        equals: .composer,
        accessibilityLabel: "Agent message"
      )
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityLabel("Agent message")
      .accessibilityIdentifier(HarnessMonitorAccessibility.sessionAgentComposer(agentID))

      keyPad
    }
    .padding(metrics.composerSpacing)
    .background(
      .quaternary.opacity(0.22),
      in: RoundedRectangle(cornerRadius: metrics.terminalCornerRadius)
    )
    .background {
      GeometryReader { proxy in
        Color.clear.preference(
          key: SessionAgentComposerHeightPreferenceKey.self,
          value: proxy.size.height
        )
      }
    }
    .onPreferenceChange(SessionAgentComposerHeightPreferenceKey.self) { height in
      guard abs(backdropHeight - height) > 0.5 else { return }
      backdropHeight = height
    }
  }

  private var keyPad: some View {
    VStack(spacing: metrics.keyStackSpacing) {
      ForEach(SessionAgentComposerKeyLayout.rows, id: \.self) { row in
        HStack(spacing: metrics.keyStackSpacing) {
          ForEach(row) { key in
            keyButton(key)
          }
        }
      }
      sendButton
    }
  }

  private var sendButton: some View {
    Button(action: sendMessage) {
      Image(systemName: "paperplane.fill")
        .frame(width: metrics.keyButtonWidth)
    }
    .keyboardShortcut(.return, modifiers: [.command])
    .help("Send Message")
    .accessibilityLabel("Send Message")
    .disabled(!canSendInput)
    .frame(minWidth: metrics.controlButtonMinSize, minHeight: metrics.controlButtonMinSize)
  }

  private func keyButton(_ key: AgentTuiKey) -> some View {
    Button {
      sendKey(key)
    } label: {
      Text(key.glyph)
        .scaledFont(.body)
        .frame(width: metrics.keyButtonWidth)
    }
    .help(key.title)
    .accessibilityLabel(key.title)
    .disabled(!isActive)
    .frame(minWidth: metrics.controlButtonMinSize, minHeight: metrics.controlButtonMinSize)
  }
}

private enum SessionAgentComposerHeightPreferenceKey: PreferenceKey {
  static var defaultValue: CGFloat { 0 }

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}
