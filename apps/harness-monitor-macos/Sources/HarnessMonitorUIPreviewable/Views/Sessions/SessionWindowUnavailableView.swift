import SwiftUI

struct SessionWindowUnavailableView: View {
  let sessionID: String
  let closeWindow: () -> Void
  let openRecents: () -> Void

  var body: some View {
    ContentUnavailableView {
      Label("Session is no longer known to the daemon", systemImage: "exclamationmark.triangle")
    } description: {
      Text(sessionID)
        .textSelection(.enabled)
    } actions: {
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        Button {
          openRecents()
        } label: {
          Label("Open Recents", systemImage: "clock.arrow.circlepath")
        }
        .keyboardShortcut("o", modifiers: [.command])
        .help("Open recent sessions")

        Button(role: .cancel) {
          closeWindow()
        } label: {
          Label("Close Window", systemImage: "xmark.circle")
        }
        .keyboardShortcut(.cancelAction)
        .help("Close this stale session window")
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Session is no longer known to the daemon")
    .accessibilityValue(sessionID)
  }
}
