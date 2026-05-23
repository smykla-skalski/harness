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
      Image(systemName: "ellipsis.circle")
        .frame(width: 28, height: 28)
    }
    .menuStyle(.borderlessButton)
    .help("File actions")
    .accessibilityLabel("File actions for \(file.path)")
  }

  private var filePermalink: URL? {
    guard
      let repositoryFullName,
      !repositoryFullName.isEmpty,
      !headRefOid.isEmpty
    else {
      return nil
    }
    let encodedPath = file.path.dashboardReviewGitHubPathEncoded
    return URL(string: "https://github.com/\(repositoryFullName)/blob/\(headRefOid)/\(encodedPath)")
  }
}
