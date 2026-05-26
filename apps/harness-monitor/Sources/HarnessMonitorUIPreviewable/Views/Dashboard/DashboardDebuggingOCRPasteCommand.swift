import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension View {
  public func dashboardDebuggingOCRPasteCommand() -> some View {
    modifier(DashboardDebuggingOCRPasteCommandModifier())
  }
}

private struct DashboardDebuggingOCRPasteCommandModifier: ViewModifier {
  @Environment(\.openWindow)
  private var openWindow

  func body(content: Content) -> some View {
    content.onPasteCommand(
      of: [.fileURL, .image],
      validator: Self.imageProviders
    ) { providers in
      Task { @MainActor in
        let didQueuePaste = await DashboardDebuggingOCRPasteboardRequests.requestPaste(
          from: providers
        )
        guard didQueuePaste else {
          return
        }
        routeToDebugging()
      }
    }
  }

  private static func imageProviders(_ providers: [NSItemProvider]) -> [NSItemProvider]? {
    let acceptedProviders = providers.filter { provider in
      provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        || provider.canLoadObject(ofClass: NSImage.self)
    }
    return acceptedProviders.isEmpty ? nil : acceptedProviders
  }

  private func routeToDebugging() {
    UserDefaults.standard.set(
      DashboardWindowRoute.debugging.rawValue,
      forKey: DashboardRouteRestorationDefaults.storageKey
    )
    if let history = GlobalWindowNavigationHistoryRegistry.current {
      history.requestDashboardRoute(.debugging)
      return
    }
    openWindow.openHarnessDashboardWindow()
  }
}
