import HarnessMonitorKit
import SwiftUI

struct DashboardDependenciesRepoLabelMenuData: Equatable, Sendable {
  let sortedLabels: [DependencyUpdateRepositoryLabel]
  let frequentNames: [String]
}

@MainActor
struct DashboardDependenciesRepositorySectionHeader: View {
  let repository: String
  let itemCount: Int
  let isCollapsed: Bool
  let scheduler: DashboardDependenciesScheduler
  let onToggleCollapse: () -> Void

  var body: some View {
    let isSyncing = scheduler.repositoriesInFlight.contains(repository)
    let lastSyncedAt = scheduler.states[repository]?.lastSyncedAt
    Button(action: onToggleCollapse) {
      HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
          .font(.caption.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .frame(width: 12, alignment: .center)
        Text(repository)
        Spacer(minLength: HarnessMonitorTheme.spacingSM)
        if isSyncing {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("Syncing \(repository)")
        } else if let lastSyncedAt {
          let relative = dependenciesRelativeFormatter.localizedString(
            for: lastSyncedAt, relativeTo: .now)
          DashboardDependenciesRepositoryHeaderPill(
            title: relative,
            systemImage: "arrow.triangle.2.circlepath",
            accessibilityLabel: "Last synced \(relative)"
          )
        }
        DashboardDependenciesRepositoryHeaderPill(
          title: String(itemCount),
          accessibilityLabel: itemCountAccessibilityLabel
        )
      }
      .contentShape(.rect)
    }
    .buttonStyle(.borderless)
    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
  }

  private var itemCountAccessibilityLabel: String {
    itemCount == 1 ? "1 dependency update" : "\(itemCount) dependency updates"
  }
}

@MainActor
private struct DashboardDependenciesRepositoryHeaderPill: View {
  let title: String
  let systemImage: String?
  let accessibilityLabel: String

  @ScaledMetric(relativeTo: .caption)
  private var height = 22.0
  @ScaledMetric(relativeTo: .caption)
  private var horizontalPadding = 8.0

  init(title: String, systemImage: String? = nil, accessibilityLabel: String) {
    self.title = title
    self.systemImage = systemImage
    self.accessibilityLabel = accessibilityLabel
  }

  var body: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingXS) {
      if let systemImage {
        Image(systemName: systemImage)
          .imageScale(.small)
      }
      Text(verbatim: title)
        .monospacedDigit()
    }
    .scaledFont(.caption.weight(.semibold))
    .lineLimit(1)
    .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    .padding(.horizontal, horizontalPadding)
    .frame(height: height, alignment: .center)
    .harnessControlPillGlass(tint: HarnessMonitorTheme.controlBorder)
    .accessibilityLabel(accessibilityLabel)
  }
}

@MainActor
struct DashboardDependenciesDescriptionView: View {
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
    switch store.dependencyUpdateBodyState[pullRequestID] {
    case .loaded(let body):
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
    store.coalesceDependencyUpdateBodyEdit(
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
