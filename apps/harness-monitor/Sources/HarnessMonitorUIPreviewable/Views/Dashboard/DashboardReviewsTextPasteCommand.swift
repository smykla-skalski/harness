import AppKit
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

struct DashboardReviewsTextPasteTransferItem: Transferable, Equatable {
  let text: String

  static var transferRepresentation: some TransferRepresentation {
    DataRepresentation(importedContentType: .plainText) { data in
      Self(
        text: String(data: data, encoding: .utf8) ?? ""
      )
    }
  }
}

extension View {
  public func dashboardReviewsTextPasteCommand() -> some View {
    modifier(DashboardReviewsTextPasteCommandModifier())
  }
}

private struct DashboardReviewsTextPasteCommandModifier: ViewModifier {
  @Environment(\.openWindow)
  private var openWindow

  func body(content: Content) -> some View {
    content
      .onAppear {
        DashboardReviewsTextPasteEventMonitor.shared.install {
          handlePasteFromClipboard()
        }
      }
      .pasteDestination(for: DashboardReviewsTextPasteTransferItem.self) { items in
        guard DashboardReviewsTextPasteboardRequests.requestPaste(items) else {
          return
        }
        ensureDashboardHostAvailable()
      }
  }

  private func handlePasteFromClipboard() -> Bool {
    guard !DashboardReviewsTextPasteEventMonitor.isTextEditingFirstResponder() else {
      return false
    }
    guard DashboardReviewsTextPasteboardRequests.requestPasteFromClipboard() else {
      return false
    }
    ensureDashboardHostAvailable()
    return true
  }

  private func ensureDashboardHostAvailable() {
    if GlobalWindowNavigationHistoryRegistry.current != nil {
      return
    }
    openWindow.openHarnessDashboardWindow()
  }
}

@MainActor
private final class DashboardReviewsTextPasteEventMonitor {
  static let shared = DashboardReviewsTextPasteEventMonitor()

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

  static func isTextEditingFirstResponder() -> Bool {
    guard let responder = NSApp.keyWindow?.firstResponder else {
      return false
    }
    return responder is NSTextView || responder is NSTextField
  }

  private static func isPasteShortcut(_ event: NSEvent) -> Bool {
    let activeModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    return activeModifiers == .command
      && event.charactersIgnoringModifiers?.lowercased() == "v"
  }
}
