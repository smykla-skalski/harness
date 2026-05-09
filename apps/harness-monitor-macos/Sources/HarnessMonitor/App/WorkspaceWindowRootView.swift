import AppKit
import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

struct WorkspaceWindowRootView: View {
  private static let contentRevealMinimumSize = CGSize(width: 1_020, height: 680)
  private static let contentRevealPollAttempts = 40
  private static let contentRevealPollInterval = Duration.milliseconds(25)

  let store: HarnessMonitorStore
  let keyWindowObserver: KeyWindowObserver
  let windowCommandRouting: WindowCommandRoutingState
  let mcpWindowCommandRegistrar: HarnessMonitorMCPWindowCommandRegistrar
  @Binding var themeMode: HarnessMonitorThemeMode
  @FocusedValue(\.windowNavigation)
  private var workspaceNavigation
  @State private var showsWorkspaceContent = false

  private var contentReadiness: WindowContentReadiness {
    WindowContentReadiness(
      isReady: showsWorkspaceContent,
      stateLabel: showsWorkspaceContent ? "ready" : "stable-frame",
      placeholder: .workspaceOpening,
      prepare: { await revealWorkspaceContentIfNeeded() }
    )
  }

  private var commandRoutingStateText: String {
    let scopeLabel =
      switch windowCommandRouting.activeScope {
      case .workspace:
        "workspace"
      case .session:
        "session"
      case .main:
        "main"
      case nil:
        "nil"
      }
    return [
      "scope=\(scopeLabel)",
      "canGoBack=\(workspaceNavigation?.canGoBack ?? false)",
      "canGoForward=\(workspaceNavigation?.canGoForward ?? false)",
    ].joined(separator: ",")
  }

  var body: some View {
    HarnessMonitorWindowShell(
      windowID: HarnessMonitorWindowID.workspace,
      windowTitle: "Workspace",
      scope: .workspace,
      minimumSize: Self.contentRevealMinimumSize,
      accessibilityIdentifier: HarnessMonitorAccessibility.workspaceWindow,
      keyWindowObserver: keyWindowObserver,
      windowCommandRouting: windowCommandRouting,
      mcpWindowCommandRegistrar: mcpWindowCommandRegistrar,
      themeMode: $themeMode,
      contentReadiness: contentReadiness,
      appliesPreferredColorScheme: true,
      toast: store.toast
    ) {
      workspaceContent
    }
    .overlay { commandRoutingMarker }
  }

  private var workspaceContent: some View {
    WorkspaceWindowView(
      store: store,
      keyWindowObserver: keyWindowObserver
    )
  }

  @ViewBuilder private var commandRoutingMarker: some View {
    if HarnessMonitorUITestEnvironment.accessibilityMarkersEnabled {
      AccessibilityTextMarker(
        identifier: HarnessMonitorAccessibility.workspaceCommandRoutingState,
        text: commandRoutingStateText
      )
    }
  }

  @MainActor
  private func revealWorkspaceContentIfNeeded() async {
    guard !showsWorkspaceContent else {
      return
    }

    // Wait for AppKit to finish creating and sizing the shell window before
    // mounting the heavier split-view tree. Opening into a 0x0 window frame
    // triggers AttributeGraph churn on the first workspace layout pass.
    for _ in 0..<Self.contentRevealPollAttempts {
      await Task.yield()
      guard !Task.isCancelled else {
        return
      }
      if Self.workspaceWindowHasStableFrame() {
        showsWorkspaceContent = true
        return
      }
      try? await Task.sleep(for: Self.contentRevealPollInterval)
    }

    showsWorkspaceContent = true
  }

  private static func workspaceWindowHasStableFrame() -> Bool {
    guard let window = workspaceWindow() else {
      return false
    }
    let frame = window.frame
    return
      window.isVisible
      && !window.isMiniaturized
      && frame.width >= contentRevealMinimumSize.width
      && frame.height >= contentRevealMinimumSize.height
  }

  private static func workspaceWindow() -> NSWindow? {
    NSApplication.shared.windows.first { window in
      let identifier = window.identifier?.rawValue ?? ""
      return KeyWindowObserver.matchesWindowID(
        identifier,
        expected: HarnessMonitorWindowID.workspace
      )
    }
  }

}
