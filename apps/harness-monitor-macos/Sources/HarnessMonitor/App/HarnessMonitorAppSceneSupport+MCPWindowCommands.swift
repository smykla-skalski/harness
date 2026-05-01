import HarnessMonitorKit
import HarnessMonitorRegistry
import HarnessMonitorUIPreviewable
import SwiftUI

private struct HarnessMonitorMCPWindowCommandDescriptor: Sendable {
  let identifier: String
  let label: String
  let hint: String
  let windowID: String

  func element(enabled: Bool) -> RegistryElement {
    RegistryElement(
      identifier: identifier,
      label: label,
      hint: hint,
      kind: .menuItem,
      frame: HarnessMonitorMCPWindowCommandRegistration.frame,
      enabled: enabled
    )
  }
}

private enum HarnessMonitorMCPWindowCommandRegistration {
  static let frame = RegistryRect(x: 0, y: 0, width: 0, height: 0)
  static let descriptors = [
    HarnessMonitorMCPWindowCommandDescriptor(
      identifier: HarnessMonitorAccessibility.windowMenuWorkspaceItem,
      label: WindowMenuCommands.workspaceTitle,
      hint: "Open the Workspace window.",
      windowID: HarnessMonitorWindowID.workspace
    ),
    HarnessMonitorMCPWindowCommandDescriptor(
      identifier: HarnessMonitorAccessibility.windowMenuMainItem,
      label: WindowMenuCommands.mainTitle,
      hint: "Open the Main window.",
      windowID: HarnessMonitorWindowID.main
    ),
  ]
}

@MainActor
final class HarnessMonitorMCPWindowCommandRegistrar {
  typealias OpenWindowHandler = @MainActor @Sendable (String) -> Void

  private let service: HarnessMonitorMCPAccessibilityService
  private var openWindowHandlers: [UUID: OpenWindowHandler] = [:]
  private var ownerPriority: [UUID] = []

  init(service: HarnessMonitorMCPAccessibilityService = .shared) {
    self.service = service
    Task { @MainActor [weak self] in
      await self?.publishPersistentMenuItems()
    }
  }

  func installOpenWindow(
    _ openWindow: @escaping OpenWindowHandler,
    ownerID: UUID
  ) async {
    openWindowHandlers[ownerID] = openWindow
    ownerPriority.removeAll { $0 == ownerID }
    ownerPriority.append(ownerID)
    await publishPersistentMenuItems()
  }

  func uninstallOpenWindow(ownerID: UUID) async {
    openWindowHandlers[ownerID] = nil
    ownerPriority.removeAll { $0 == ownerID }
    await publishPersistentMenuItems()
  }

  /// Keep the registry entries app-owned while any live scene root can supply
  /// the actual `openWindow` closure. The newest live owner wins; when no
  /// owners remain, the commands stay published but disabled.
  private var currentOpenWindowHandler: OpenWindowHandler? {
    ownerPriority.reversed().lazy.compactMap { self.openWindowHandlers[$0] }.first
  }

  private var commandsEnabled: Bool {
    currentOpenWindowHandler != nil
  }

  private func publishPersistentMenuItems() async {
    for descriptor in HarnessMonitorMCPWindowCommandRegistration.descriptors {
      await service.registerPersistentSemanticElement(
        descriptor.element(enabled: commandsEnabled),
        semanticActions: semanticActions(for: descriptor.windowID)
      )
    }
  }

  private func semanticActions(for windowID: String) -> RegistryTrackedSemanticActions {
    RegistryTrackedSemanticActions(press: { [weak self] in
      self?.currentOpenWindowHandler?(windowID)
    })
  }
}

private struct HarnessMonitorMCPWindowCommandsModifier: ViewModifier {
  let registrar: HarnessMonitorMCPWindowCommandRegistrar

  @Environment(\.openWindow)
  private var openWindow
  @State private var registrationOwnerID = UUID()

  func body(content: Content) -> some View {
    content
      .task(id: registrationOwnerID) {
        await registrar.installOpenWindow(
          { windowID in
            openWindow(id: windowID)
          },
          ownerID: registrationOwnerID
        )
      }
      .onDisappear {
        let ownerID = registrationOwnerID
        Task { @MainActor in
          await registrar.uninstallOpenWindow(ownerID: ownerID)
        }
      }
  }
}

extension View {
  func harnessMonitorMCPWindowCommands(
    registrar: HarnessMonitorMCPWindowCommandRegistrar
  ) -> some View {
    modifier(HarnessMonitorMCPWindowCommandsModifier(registrar: registrar))
  }
}
