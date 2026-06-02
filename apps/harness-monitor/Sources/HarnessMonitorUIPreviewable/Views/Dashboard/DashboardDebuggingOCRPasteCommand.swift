import AppKit
import SwiftUI

extension View {
  public func dashboardDebuggingOCRPasteCommand() -> some View {
    modifier(DashboardDebuggingOCRPasteCommandModifier())
  }
}

private struct DashboardDebuggingOCRPasteCommandModifier: ViewModifier {
  @Environment(\.openWindow)
  private var openWindow

  func body(content: Content) -> some View {
    content
      .onAppear {
        DashboardDebuggingOCRPasteEventMonitor.shared.install {
          handlePasteFromClipboard()
        }
      }
      .pasteDestination(for: DashboardOCRTransferImage.self) { images in
        let result = DashboardImagePastePolicyDispatcher.requestPaste(
          from: images,
          reviewsRouteActive: isReviewsRouteActive
        )
        if result == .manualOCRPaste {
          routeToDebugging()
        }
      }
  }

  private func handlePasteFromClipboard() -> Bool {
    let result = DashboardImagePastePolicyDispatcher.requestPasteFromClipboard(
      reviewsRouteActive: isReviewsRouteActive
    )
    guard result != .notHandled else {
      return false
    }
    if result == .manualOCRPaste {
      routeToDebugging()
    }
    return true
  }

  private var isReviewsRouteActive: Bool {
    GlobalWindowNavigationHistoryRegistry.current?.currentDashboardRoute == .reviews
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

@MainActor
private final class DashboardDebuggingOCRPasteEventMonitor {
  static let shared = DashboardDebuggingOCRPasteEventMonitor()

  private var monitor: Any?
  private var handlePaste: (@MainActor () -> Bool)?

  func install(handlePaste: @escaping @MainActor () -> Bool) {
    self.handlePaste = handlePaste
    guard monitor == nil else {
      return
    }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      self?.handle(event) ?? event
    }
  }

  private func handle(_ event: NSEvent) -> NSEvent? {
    guard Self.isPasteShortcut(event) else {
      return event
    }
    guard handlePaste?() == true else {
      return event
    }
    return nil
  }

  private static func isPasteShortcut(_ event: NSEvent) -> Bool {
    let activeModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    return activeModifiers == .command
      && event.charactersIgnoringModifiers?.lowercased() == "v"
  }
}
