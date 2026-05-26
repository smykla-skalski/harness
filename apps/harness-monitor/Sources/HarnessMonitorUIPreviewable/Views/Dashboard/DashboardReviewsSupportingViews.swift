import HarnessMonitorKit
import SwiftUI

struct DashboardReviewsRepoLabelMenuData: Equatable, Sendable {
  let sortedLabels: [ReviewRepositoryLabel]
  let labelByName: [String: ReviewRepositoryLabel]
  let frequentNames: [String]
}

@MainActor
struct DashboardReviewsDescriptionView: View {
  let store: HarnessMonitorStore
  let pullRequestID: String
  let viewerCanUpdate: Bool
  let onCheckboxError: ((String) -> Void)?
  let onCheckboxUpdated: (() -> Void)?
  let onRetryLoad: (() -> Void)?

  init(
    store: HarnessMonitorStore,
    pullRequestID: String,
    viewerCanUpdate: Bool = true,
    onCheckboxError: ((String) -> Void)? = nil,
    onCheckboxUpdated: (() -> Void)? = nil,
    onRetryLoad: (() -> Void)? = nil
  ) {
    self.store = store
    self.pullRequestID = pullRequestID
    self.viewerCanUpdate = viewerCanUpdate
    self.onCheckboxError = onCheckboxError
    self.onCheckboxUpdated = onCheckboxUpdated
    self.onRetryLoad = onRetryLoad
  }

  var body: some View {
    switch store.reviewBodyState[pullRequestID] {
    case .loaded(let body):
      loadedBody(body)
    case .failed(let message):
      DashboardReviewDescriptionFailedView(rawMessage: message, onRetry: onRetryLoad)
    case .loading, nil:
      DashboardReviewDescriptionLoadingView()
    }
  }

  @ViewBuilder
  private func loadedBody(_ body: String) -> some View {
    if body.isEmpty {
      Text("No description")
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .scaledFont(.callout)
    } else if viewerCanUpdate {
      HarnessMonitorMarkdownText(body, textSelection: .enabled)
        .markdownCheckboxToggle { offset, newValue in
          toggleCheckbox(currentBody: body, offset: offset, newValue: newValue)
        }
    } else {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        if dashboardReviewBodyHasTaskListCheckbox(body) {
          DashboardReviewDescriptionReadOnlyNotice()
        }
        HarnessMonitorMarkdownText(body, textSelection: .enabled)
          .opacity(dashboardReviewBodyHasTaskListCheckbox(body) ? 0.92 : 1)
          .help("You don't have permission to update this pull request.")
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
        onError?(
          "PR description was updated by someone else. Try your change again on the refreshed body."
        )
      case .failed(let message):
        onError?("Couldn't update PR body: \(message)")
      }
    }
  }
}

/// Returns true when `body` contains at least one GFM task-list checkbox line
/// (`- [ ]` or `- [x]` anchored at line start). Substring `- [` alone would
/// false-positive on Markdown links such as `- [text](url)`.
func dashboardReviewBodyHasTaskListCheckbox(_ body: String) -> Bool {
  body.range(of: #"(?m)^[ \t]*-[ \t]+\[[ xX]\]"#, options: .regularExpression) != nil
}

private struct DashboardReviewDescriptionReadOnlyNotice: View {
  var body: some View {
    Label(
      "Read-only — you don't have permission to flip these checkboxes.",
      systemImage: "lock"
    )
    .scaledFont(.caption.weight(.semibold))
    .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    .padding(.horizontal, 9)
    .padding(.vertical, 6)
    .background(
      HarnessMonitorTheme.ink.opacity(0.06),
      in: RoundedRectangle(cornerRadius: 7, style: .continuous)
    )
    .accessibilityElement(children: .combine)
  }
}

private struct DashboardReviewDescriptionLoadingView: View {
  @State private var elapsedSeconds: Int = 0
  private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        ProgressView()
          .controlSize(.small)
        Text("Loading description…")
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .scaledFont(.callout)
      }
      if elapsedSeconds >= 10 {
        Text(
          "Still loading — check your daemon connection if this persists."
        )
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.caution)
        .padding(.leading, 22)
      }
    }
    .onReceive(timer) { _ in
      if elapsedSeconds < 30 {
        elapsedSeconds += 1
      }
    }
  }
}

private struct DashboardReviewDescriptionFailedView: View {
  let rawMessage: String
  let onRetry: (() -> Void)?

  @State private var showsDetails = false

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(HarnessMonitorTheme.danger)
        Text("Couldn't load the PR description.")
          .scaledFont(.callout.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.ink)
        Spacer(minLength: 0)
      }
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        if let onRetry {
          Button("Retry") { onRetry() }
            .harnessActionButtonStyle(variant: .prominent)
            .controlSize(.small)
            .accessibilityHint("Re-fetches the pull request description.")
        }
        Button(showsDetails ? "Hide details" : "Show details") {
          showsDetails.toggle()
        }
        .harnessGlassButtonStyle()
        .controlSize(.small)
        .accessibilityHint("Shows the daemon error string that caused the failure.")
      }
      if showsDetails {
        Text(rawMessage.isEmpty ? "No detail provided." : rawMessage)
          .scaledFont(.caption.monospaced())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .textSelection(.enabled)
          .padding(8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            HarnessMonitorTheme.ink.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
          )
      }
    }
    .padding(.vertical, HarnessMonitorTheme.spacingXS)
  }
}
