import HarnessMonitorKit
import SwiftUI

extension DashboardReviewFileCardInternal {
  var fileActionsMenu: some View {
    Menu {
      Button("Copy Path") {
        HarnessMonitorClipboard.copy(file.path)
      }
      if let permalink = filePermalink {
        Button("Copy GitHub Permalink") {
          HarnessMonitorClipboard.copy(permalink.absoluteString)
        }
        Button("Open on GitHub") {
          openURL(permalink)
        }
      }
      if !threads.isEmpty {
        Divider()
        Button("Copy Thread URLs") {
          HarnessMonitorClipboard.copy(
            threads.compactMap(\.url).joined(separator: "\n")
          )
        }
        .disabled(threads.allSatisfy { $0.url == nil })
      }
    } label: {
      Label("More", systemImage: "ellipsis.circle")
        .lineLimit(1)
    }
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
    .fixedSize(horizontal: true, vertical: true)
    .help("Show more file actions")
    .accessibilityLabel("More file actions for \(file.path)")
  }

  private var filePermalink: URL? {
    dashboardReviewFileBlobURL(
      repositoryFullName: repositoryFullName,
      headRefOid: headRefOid,
      path: file.path
    )
  }
}
