import HarnessMonitorKit
import SwiftUI

struct SessionWindowToolbarModel: Equatable {
  let canNavigateBack: Bool
  let canNavigateForward: Bool
  let sleepPreventionPresentation: SleepPreventionToolbarPresentation
}

struct SessionWindowToolbar: ToolbarContent {
  let store: HarnessMonitorStore
  let model: SessionWindowToolbarModel
  let state: SessionWindowStateCache
  @Binding var focusMode: Bool
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .navigation) {
      Button {
        state.navigateBack()
      } label: {
        Label {
          Text("Go back")
        } icon: {
          Image(systemName: "chevron.backward")
            .frame(width: 14, height: 14)
        }
      }
      .disabled(!model.canNavigateBack)
      .help("Go back")
      .accessibilityLabel("Back")
      .accessibilityIdentifier(HarnessMonitorAccessibility.sessionNavigateBackButton)

      Button {
        state.navigateForward()
      } label: {
        Label {
          Text("Go forward")
        } icon: {
          Image(systemName: "chevron.forward")
            .frame(width: 14, height: 14)
        }
      }
      .disabled(!model.canNavigateForward)
      .help("Go forward")
      .accessibilityLabel("Forward")
      .accessibilityIdentifier(HarnessMonitorAccessibility.sessionNavigateForwardButton)
    }
    ToolbarItem(placement: .automatic) {
      Button {
        toggleFocusMode()
      } label: {
        Label {
          Text(focusMode ? "Exit focus mode" : "Enter focus mode")
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
        presentation: model.sleepPreventionPresentation
      )
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
