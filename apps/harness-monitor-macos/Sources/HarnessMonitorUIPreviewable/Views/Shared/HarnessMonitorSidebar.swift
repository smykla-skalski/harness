import SwiftUI

private struct HarnessMonitorSidebarListChromeModifier: ViewModifier {
  let rowSize: SidebarRowSize

  func body(content: Content) -> some View {
    content
      .listStyle(.sidebar)
      .transaction { transaction in
        transaction.animation = nil
        transaction.disablesAnimations = true
      }
      .environment(\.sidebarRowSize, rowSize)
  }
}

struct HarnessMonitorSidebar<Content: View>: View {
  private let accessibilityIdentifier: String
  private let accessibilityValue: Text
  private let statusModel: SessionStatusSummaryModel
  private let content: Content

  init(
    accessibilityIdentifier: String,
    accessibilityValue: Text = Text(""),
    statusModel: SessionStatusSummaryModel,
    @ViewBuilder content: () -> Content
  ) {
    self.accessibilityIdentifier = accessibilityIdentifier
    self.accessibilityValue = accessibilityValue
    self.statusModel = statusModel
    self.content = content()
  }

  var body: some View {
    content
      .safeAreaInset(edge: .bottom, spacing: 0) {
        SessionSidebarFooter(model: statusModel)
      }
      .accessibilityIdentifier(accessibilityIdentifier)
      .accessibilityValue(accessibilityValue)
  }
}

extension View {
  func harnessMonitorSidebarListChrome(rowSize: SidebarRowSize) -> some View {
    modifier(HarnessMonitorSidebarListChromeModifier(rowSize: rowSize))
  }
}
