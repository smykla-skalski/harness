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
  let currentModifiers: EventModifiers
  @ScaledMetric(relativeTo: .caption)
  private var sidebarShortcutKeySpacing =
    HarnessMonitorTheme.spacingXS - 1
  @ScaledMetric(relativeTo: .caption)
  private var sidebarShortcutHorizontalOffset = 56
  @ScaledMetric(relativeTo: .caption)
  private var sidebarShortcutVerticalOffset = 12
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  private let sidebarShortcut = KeyboardShortcutDescriptor.toggleSidebar

  private var shouldShowShortcutOverlays: Bool {
    !HarnessMonitorUITestEnvironment.disablesVisualOptions
      && SessionWindowKeyboardShortcutOverlaySettings.read()
  }

  private var shouldRenderShortcutOverlay: Bool {
    shouldShowShortcutOverlays && sidebarShortcut.isRevealed(by: currentModifiers)
  }

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
      .harnessMCPButton(
        HarnessMonitorAccessibility.sessionNavigateBackButton,
        label: "Back",
        hint: "Go back",
        enabled: model.canNavigateBack,
        pressAction: { state.navigateBack() }
      )
      .overlay(alignment: .bottom) {
        if shouldRenderShortcutOverlay {
          KeyboardShortcutLabel(
            shortcut: sidebarShortcut,
            activeModifiers: currentModifiers,
            revealPolicy: .revealOnRelevantModifierHold,
            keySpacing: sidebarShortcutKeySpacing
          )
          .fixedSize(horizontal: true, vertical: true)
          .offset(x: -sidebarShortcutHorizontalOffset, y: sidebarShortcutVerticalOffset)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
        }
      }
      .zIndex(
        shouldRenderShortcutOverlay ? 1 : 0
      )

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
      .harnessMCPButton(
        HarnessMonitorAccessibility.sessionNavigateForwardButton,
        label: "Forward",
        hint: "Go forward",
        enabled: model.canNavigateForward,
        pressAction: { state.navigateForward() }
      )
    }
    ToolbarItem(placement: .automatic) {
      Button {
        toggleFocusMode()
      } label: {
        Label {
          Text(focusMode ? "Exit focus mode" : "Enter focus mode")
        } icon: {
          Image(systemName: focusMode ? "moon.fill" : "moon")
            .frame(width: 14, height: 14)
        }
      }
      .help(focusMode ? "Exit focus mode" : "Enter focus mode")
      .accessibilityLabel("Focus mode")
      .accessibilityValue(focusMode ? "On" : "Off")
      .accessibilityHint("Shows or hides secondary session columns.")
      .harnessMCPButton(
        HarnessMonitorAccessibility.sessionWindowFocusModeButton,
        label: "Focus mode",
        value: focusMode ? "On" : "Off",
        hint: "Shows or hides secondary session columns.",
        pressAction: { toggleFocusMode() }
      )
    }
    ToolbarItem(placement: .primaryAction) {
      SleepPreventionToolbarButton(
        store: store,
        presentation: model.sleepPreventionPresentation
      )
    }
  }

  private func toggleFocusMode() {
    focusMode.toggle()
  }
}
