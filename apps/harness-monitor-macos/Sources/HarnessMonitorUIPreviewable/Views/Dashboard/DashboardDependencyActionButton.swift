import HarnessMonitorKit
import SwiftUI

enum DashboardDependencyActionProminence {
  case primary
  case success
  case warning
  case destructive
  case secondary
  case utility

  var variant: HarnessMonitorAsyncActionButton.Variant {
    switch self {
    case .primary, .success, .warning, .destructive:
      .prominent
    case .secondary, .utility:
      .bordered
    }
  }

  var tint: Color? {
    switch self {
    case .primary:
      nil
    case .success:
      .green
    case .warning:
      .orange
    case .destructive:
      .red
    case .secondary:
      nil
    case .utility:
      .secondary
    }
  }
}

struct DashboardDependencyActionButton: View {
  let title: String
  let systemImage: String
  let prominence: DashboardDependencyActionProminence
  let helpText: String?
  let action: () -> Void

  init(
    title: String,
    systemImage: String,
    prominence: DashboardDependencyActionProminence,
    helpText: String? = nil,
    action: @escaping () -> Void
  ) {
    self.title = title
    self.systemImage = systemImage
    self.prominence = prominence
    self.helpText = helpText
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .lineLimit(1)
    }
    .harnessActionButtonStyle(variant: prominence.variant, tint: prominence.tint)
    .fixedSize(horizontal: true, vertical: true)
    .modifier(DashboardDependencyActionButtonHelpModifier(helpText: helpText))
  }
}

private struct DashboardDependencyActionButtonHelpModifier: ViewModifier {
  let helpText: String?

  func body(content: Content) -> some View {
    if let helpText {
      content.help(helpText)
    } else {
      content
    }
  }
}
