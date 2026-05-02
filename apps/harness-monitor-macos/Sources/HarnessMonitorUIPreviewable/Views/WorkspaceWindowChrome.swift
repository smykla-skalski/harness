import SwiftUI

struct ClickableSwitchStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack {
      configuration.label
        .contentShape(Rectangle())
        .onTapGesture {
          configuration.isOn.toggle()
        }
      Toggle("", isOn: configuration.$isOn)
        .toggleStyle(.switch)
        .labelsHidden()
    }
  }
}

enum WorkspaceChromeMetrics {
  static let sidebarMinWidth: CGFloat = 240
  static let sidebarIdealWidth: CGFloat = 280
  static let sidebarMaxWidth: CGFloat = 400
  static let decisionInspectorWidth: CGFloat = 260
}
