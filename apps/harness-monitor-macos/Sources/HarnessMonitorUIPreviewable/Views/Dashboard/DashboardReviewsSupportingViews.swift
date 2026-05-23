import HarnessMonitorKit
import SwiftUI

struct DashboardReviewsRepoLabelMenuData: Equatable, Sendable {
  let sortedLabels: [ReviewRepositoryLabel]
  let frequentNames: [String]
}

@MainActor
struct DashboardReviewsDescriptionView: View {
  let store: HarnessMonitorStore
  let pullRequestID: String
  let viewerCanUpdate: Bool
  let onCheckboxError: ((String) -> Void)?
  let onCheckboxUpdated: (() -> Void)?

  init(
    store: HarnessMonitorStore,
    pullRequestID: String,
    viewerCanUpdate: Bool = true,
    onCheckboxError: ((String) -> Void)? = nil,
    onCheckboxUpdated: (() -> Void)? = nil
  ) {
    self.store = store
    self.pullRequestID = pullRequestID
    self.viewerCanUpdate = viewerCanUpdate
    self.onCheckboxError = onCheckboxError
    self.onCheckboxUpdated = onCheckboxUpdated
  }

  var body: some View {
    switch store.reviewBodyState[pullRequestID] {
    case .loaded(let body):
      if body.isEmpty {
        Text("No description")
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .scaledFont(.callout)
      } else if viewerCanUpdate {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
          if body.contains("- [") {
            DashboardReviewDescriptionCheckboxNotice()
          }
          HarnessMonitorMarkdownText(body, textSelection: .enabled)
            .markdownCheckboxToggle { offset, newValue in
              toggleCheckbox(currentBody: body, offset: offset, newValue: newValue)
            }
        }
      } else {
        HarnessMonitorMarkdownText(body, textSelection: .enabled)
      }
    case .failed(let message):
      Text(message)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .scaledFont(.callout)
    case .loading, nil:
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        ProgressView()
          .controlSize(.small)
        Text("Loading description…")
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .scaledFont(.callout)
      }
    }
  }

  private func toggleCheckbox(currentBody: String, offset: Int, newValue: Bool) {
    var bytes = Array(currentBody.utf8)
    guard offset < bytes.count else { return }
    bytes[offset] = newValue ? 0x78 : 0x20
    guard let newBody = String(bytes: bytes, encoding: .utf8) else { return }
    let onUpdated = onCheckboxUpdated
    let onError = onCheckboxError
    store.coalesceReviewBodyEdit(
      pullRequestID: pullRequestID,
      newBody: newBody,
      priorBody: currentBody
    ) { outcome in
      switch outcome {
      case .updated:
        onUpdated?()
      case .bodyDrifted:
        onError?("PR body changed since you opened it. Reloaded the latest version.")
      case .failed(let message):
        onError?("Couldn't update PR body: \(message)")
      }
    }
  }
}

private struct DashboardReviewDescriptionCheckboxNotice: View {
  var body: some View {
    Label(
      "Task-list checkboxes update the pull request description.",
      systemImage: "checklist"
    )
    .scaledFont(.caption.weight(.semibold))
    .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    .padding(.horizontal, 9)
    .padding(.vertical, 6)
    .background(
      HarnessMonitorTheme.accent.opacity(0.08),
      in: RoundedRectangle(cornerRadius: 7, style: .continuous)
    )
    .accessibilityElement(children: .combine)
  }
}
