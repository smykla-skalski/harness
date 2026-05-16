import SwiftUI

struct SettingsSecretField: View {
  let title: String
  let placeholder: String
  @Binding var text: String
  let accessibilityIdentifier: String

  @State private var isRevealed = false

  var body: some View {
    HStack(spacing: 6) {
      Group {
        if isRevealed {
          TextField(placeholder, text: $text)
            .textContentType(.password)
        } else {
          SecureField(placeholder, text: $text)
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
}
