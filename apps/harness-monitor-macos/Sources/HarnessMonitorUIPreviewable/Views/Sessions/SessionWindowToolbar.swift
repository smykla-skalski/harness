import HarnessMonitorKit
import SwiftUI

struct SessionWindowToolbar: ToolbarContent {
  let store: HarnessMonitorStore
  let snapshot: HarnessMonitorSessionWindowSnapshot?
  let connectionTitle: String
  let statusSystemImage: String
  let sessionID: String
  let state: SessionWindowStateCache
  @Binding var focusMode: Bool
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  private var sleepPreventionPresentation: SleepPreventionToolbarPresentation {
    SleepPreventionToolbarPresentation(isEnabled: store.sleepPreventionEnabled)
  }

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .navigation) {
      Button {
        state.navigateBack()
      } label: {
        Label("Back", systemImage: "chevron.backward")
      }
      .disabled(!state.navigationHistory.canGoBack)
      .help("Go back")
      .accessibilityIdentifier(HarnessMonitorAccessibility.sessionNavigateBackButton)

      Button {
        state.navigateForward()
      } label: {
        Label("Forward", systemImage: "chevron.forward")
      }
      .disabled(!state.navigationHistory.canGoForward)
      .help("Go forward")
      .accessibilityIdentifier(HarnessMonitorAccessibility.sessionNavigateForwardButton)
    }
    ToolbarItem(placement: .automatic) {
      Button {
        toggleFocusMode()
      } label: {
        Label {
          Text("Focus Mode")
        } icon: {
          Image(systemName: focusMode ? "moon.fill" : "moon")
            .contentTransition(
              .symbolEffect(
                .replace.magic(fallback: .downUp.wholeSymbol),
                options: .nonRepeating
              )
            )
            .frame(width: 14, height: 14)
        }
      }
      .help(focusMode ? "Exit focus mode" : "Enter focus mode")
      .accessibilityIdentifier(HarnessMonitorAccessibility.sessionWindowFocusModeButton)
      .accessibilityLabel("Focus mode")
      .accessibilityValue(focusMode ? "On" : "Off")
      .accessibilityHint("Shows or hides secondary session columns.")
    }
    ToolbarItem(placement: .primaryAction) {
      SleepPreventionToolbarButton(
        store: store,
        presentation: sleepPreventionPresentation
      )
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
    }
  }

  private func toggleFocusMode() {
    let animation = SessionFocusModeMotionPolicy.animation(reduceMotion: reduceMotion)
    if let animation {
      withAnimation(animation) {
        focusMode.toggle()
      }
    } else {
      focusMode.toggle()
    }
  }
}
