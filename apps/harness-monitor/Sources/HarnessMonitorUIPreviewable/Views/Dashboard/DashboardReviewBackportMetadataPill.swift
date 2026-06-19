import HarnessMonitorKit
import SwiftUI

struct DashboardReviewBackportMetadataPill: View {
  let source: ReviewBackportSource

  @Environment(\.openURL)
  private var openURL

  private var destination: URL? {
    URL(string: source.url)
  }

  private var copyValue: String {
    "\(source.repository)#\(source.number)"
  }

  var body: some View {
    Button {
      if let destination {
        openURL(destination)
      }
    } label: {
      DashboardReviewStatusPill(
        label: "#\(source.number)",
        tint: HarnessMonitorTheme.accent,
        systemImage: "arrow.uturn.backward",
        isQuiet: true,
        help: "Backport of \(copyValue)"
      )
    }
    .harnessPlainButtonStyle()
    .contextMenu {
      DashboardReviewCopyableLinkContextMenu(
        valueTitle: "Copy Backported PR",
        value: copyValue,
        urlTitle: "Copy Backported PR URL",
        openTitle: "Open Backported PR",
        destination: destination
      )
    }
    .help("Backport of \(copyValue)")
  }
}
