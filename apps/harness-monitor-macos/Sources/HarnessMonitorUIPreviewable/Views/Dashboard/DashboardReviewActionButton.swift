import HarnessMonitorKit
import SwiftUI

enum DashboardReviewActionProminence {
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

struct DashboardReviewActionButton: View {
  let title: String
  let systemImage: String
  let prominence: DashboardReviewActionProminence
  let helpText: String?
  let action: () -> Void

  init(
    title: String,
    systemImage: String,
    prominence: DashboardReviewActionProminence,
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
    .modifier(DashboardReviewActionButtonHelpModifier(helpText: helpText))
  }
}

private struct DashboardReviewActionButtonHelpModifier: ViewModifier {
  let helpText: String?

  func body(content: Content) -> some View {
    if let helpText {
      content.help(helpText)
    } else {
      content
    }
  }
}
