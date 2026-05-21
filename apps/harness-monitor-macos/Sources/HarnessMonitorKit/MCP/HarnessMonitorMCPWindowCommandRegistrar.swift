import HarnessMonitorRegistry
import SwiftUI

public struct HarnessMonitorMCPWindowCommandDescriptor: Sendable, Equatable {
  public let identifier: String
  public let label: String
  public let hint: String
  public let windowID: String

  public init(identifier: String, label: String, hint: String, windowID: String) {
    self.identifier = identifier
    self.label = label
    self.hint = hint
    self.windowID = windowID
  }
}

private enum HarnessMonitorMCPWindowCommandRegistration {
  static let frame = RegistryRect(x: 0, y: 0, width: 0, height: 0)
}

extension HarnessMonitorMCPWindowCommandDescriptor {
  fileprivate func element(enabled: Bool) -> RegistryElement {
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

@MainActor
public final class HarnessMonitorMCPWindowCommandRegistrar {
  typealias OpenWindowHandler = @MainActor @Sendable (String) -> Void

  private let service: HarnessMonitorMCPAccessibilityService
  private let descriptors: [HarnessMonitorMCPWindowCommandDescriptor]
  private var openWindowHandlers: [UUID: OpenWindowHandler] = [:]
  private var ownerPriority: [UUID] = []

  public init(
    descriptors: [HarnessMonitorMCPWindowCommandDescriptor],
    service: HarnessMonitorMCPAccessibilityService = .shared
  ) {
    self.service = service
    self.descriptors = descriptors
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

  private var currentOpenWindowHandler: OpenWindowHandler? {
    ownerPriority.reversed().lazy.compactMap { self.openWindowHandlers[$0] }.first
  }

  private var commandsEnabled: Bool {
    currentOpenWindowHandler != nil
  }

  private func publishPersistentMenuItems() async {
    for descriptor in descriptors {
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
  public func harnessMonitorMCPWindowCommands(
    registrar: HarnessMonitorMCPWindowCommandRegistrar
  ) -> some View {
    modifier(HarnessMonitorMCPWindowCommandsModifier(registrar: registrar))
  }

  public func harnessTrackMCPWindow(
    service: HarnessMonitorMCPAccessibilityService = .shared,
    tracksElements: Bool = true
  ) -> some View {
    trackWindow(registry: service.registry, tracksElements: tracksElements)
  }
}
