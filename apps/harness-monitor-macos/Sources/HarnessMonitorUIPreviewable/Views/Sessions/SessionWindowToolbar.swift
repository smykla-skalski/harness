import HarnessMonitorKit
import SwiftUI

struct SessionWindowToolbarModel: Equatable {
  let canNavigateBack: Bool
  let canNavigateForward: Bool
  let sleepPreventionPresentation: SleepPreventionToolbarPresentation
}

struct WindowHistoryToolbarShortcutOverlay {
  let shortcut: KeyboardShortcutDescriptor
  let currentModifiers: EventModifiers
}

struct WindowHistoryToolbarItems: ToolbarContent {
  let navigation: WindowNavigationState
  let backAccessibilityIdentifier: String
  let forwardAccessibilityIdentifier: String
  let shortcutOverlay: WindowHistoryToolbarShortcutOverlay?
  @ScaledMetric(relativeTo: .caption)
  private var sidebarShortcutKeySpacing =
    HarnessMonitorTheme.spacingXS - 1
  @ScaledMetric(relativeTo: .caption)
  private var sidebarShortcutHorizontalOffset = 56
  @ScaledMetric(relativeTo: .caption)
  private var sidebarShortcutVerticalOffset = 12

  private var shouldRenderShortcutOverlay: Bool {
    guard let shortcutOverlay else {
      return false
    }
    return shortcutOverlay.shortcut.isRevealed(by: shortcutOverlay.currentModifiers)
  }

  @ToolbarContentBuilder var body: some ToolbarContent {
    ToolbarItemGroup(placement: .navigation) {
      Button {
        navigation.navigateBack()
      } label: {
        Label {
          Text("Go back")
        } icon: {
          Image(systemName: "chevron.backward")
            .frame(width: 14, height: 14)
        }
      }
      .disabled(!navigation.canGoBack)
      .help("Go back")
      .accessibilityIdentifier(backAccessibilityIdentifier)
      .accessibilityLabel("Back")
      .harnessMCPButton(
        backAccessibilityIdentifier,
        label: "Back",
        hint: "Go back",
        enabled: navigation.canGoBack,
        pressAction: {
          Task { @MainActor in
            navigation.navigateBack()
          }
        }
      )
      .overlay(alignment: .bottom) {
        if let shortcutOverlay, shouldRenderShortcutOverlay {
          KeyboardShortcutLabel(
            shortcut: shortcutOverlay.shortcut,
            activeModifiers: shortcutOverlay.currentModifiers,
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
        navigation.navigateForward()
      } label: {
        Label {
          Text("Go forward")
        } icon: {
          Image(systemName: "chevron.forward")
            .frame(width: 14, height: 14)
        }
      }
      .disabled(!navigation.canGoForward)
      .help("Go forward")
      .accessibilityIdentifier(forwardAccessibilityIdentifier)
      .accessibilityLabel("Forward")
      .harnessMCPButton(
        forwardAccessibilityIdentifier,
        label: "Forward",
        hint: "Go forward",
        enabled: navigation.canGoForward,
        pressAction: {
          Task { @MainActor in
            navigation.navigateForward()
          }
        }
      )
    }
  }
}

struct SessionWindowToolbar: ToolbarContent {
  let store: HarnessMonitorStore
  let model: SessionWindowToolbarModel
  let navigation: WindowNavigationState
  @Binding var focusMode: Bool
  let currentModifiers: EventModifiers

  private let sidebarShortcut = KeyboardShortcutDescriptor.toggleSidebar

  private var historyShortcutOverlay: WindowHistoryToolbarShortcutOverlay? {
    guard
      !HarnessMonitorUITestEnvironment.disablesVisualOptions
        && SessionWindowKeyboardShortcutOverlaySettings.read()
    else {
      return nil
    }
    return WindowHistoryToolbarShortcutOverlay(
      shortcut: sidebarShortcut,
      currentModifiers: currentModifiers
    )
  }

  var body: some ToolbarContent {
    WindowHistoryToolbarItems(
      navigation: navigation,
      backAccessibilityIdentifier:
        HarnessMonitorAccessibility.sessionNavigateBackButton,
      forwardAccessibilityIdentifier:
        HarnessMonitorAccessibility.sessionNavigateForwardButton,
      shortcutOverlay: historyShortcutOverlay
    )

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
        hint: "Shows or hides secondary session columns",
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
