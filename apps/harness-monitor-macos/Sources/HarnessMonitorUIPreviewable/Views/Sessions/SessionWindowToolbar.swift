import HarnessMonitorKit
import SwiftUI

struct SessionWindowToolbar: ToolbarContent {
  let snapshot: HarnessMonitorSessionWindowSnapshot?
  let connectionTitle: String
  let statusSystemImage: String
  let sessionID: String
  @Binding var focusMode: Bool

  var body: some ToolbarContent {
    ToolbarItem(placement: .automatic) {
      Toggle(isOn: $focusMode) {
        Label("Focus Mode", systemImage: "sidebar.leading")
      }
      .toggleStyle(.button)
      .buttonStyle(SessionToolbarButtonStyle(isSelected: focusMode))
      .accessibilityLabel("Focus mode")
      .accessibilityHint("Shows or hides secondary session columns.")
    }
    ToolbarItem(placement: .automatic) {
      Menu {
        Text("Connection: \(connectionTitle)")
        Text("Source: \(snapshot?.source.rawValue ?? "loading")")
        if let summary = snapshot?.summary {
          Text("Status: \(summary.status.title)")
        }
        Text("Session: \(sessionID)")
      } label: {
        Label("Session Status", systemImage: statusSystemImage)
      }
      .accessibilityIdentifier(HarnessMonitorAccessibility.sessionWindowStatusMenu)
      .accessibilityLabel("Session status")
      .accessibilityHint("Shows current connection and session status.")
      .buttonStyle(SessionToolbarButtonStyle())
    }
  }
}
