import HarnessMonitorKit
import SwiftUI

struct DashboardDependencyDetailView<Actions: View>: View {
  let item: DependencyUpdateItem
  let store: HarnessMonitorStore
  let activity: DashboardDependencyActivitySnapshot
  @Binding var showsProblemChecksOnly: Bool
  let onDescriptionCheckboxError: ((String) -> Void)?
  let onDescriptionCheckboxUpdated: (() -> Void)?
  let onRerunCheck: (DependencyUpdateCheck) -> Void
  @ViewBuilder let actionBar: () -> Actions

  @Environment(\.dependenciesPreferences) private var dependenciesPreferences

  private var filesEnabled: Bool {
    dependenciesPreferences.snapshot.filesEnabled
  }

  init(
    item: DependencyUpdateItem,
    store: HarnessMonitorStore,
    activity: DashboardDependencyActivitySnapshot,
    showsProblemChecksOnly: Binding<Bool> = .constant(false),
    onDescriptionCheckboxError: ((String) -> Void)? = nil,
    onDescriptionCheckboxUpdated: (() -> Void)? = nil,
    onRerunCheck: @escaping (DependencyUpdateCheck) -> Void = { _ in },
    @ViewBuilder actionBar: @escaping () -> Actions
  ) {
    self.item = item
    self.store = store
    self.activity = activity
    _showsProblemChecksOnly = showsProblemChecksOnly
    self.onDescriptionCheckboxError = onDescriptionCheckboxError
    self.onDescriptionCheckboxUpdated = onDescriptionCheckboxUpdated
    self.onRerunCheck = onRerunCheck
    self.actionBar = actionBar
  }

  var body: some View {
    HarnessMonitorColumnScrollView(
      horizontalPadding: 24,
      verticalPadding: 24,
      constrainContentWidth: true,
      readableWidth: false,
      topScrollEdgeEffect: .soft,
      scrollSurfaceIdentifier: HarnessMonitorAccessibility.dashboardDependenciesDetail,
      scrollSurfaceLabel: "Dependencies detail"
    ) {
      VStack(alignment: .leading, spacing: 18) {
        DashboardDependencyDetailCard(
          title: item.title,
          subtitle: "\(item.repository)#\(item.number) · @\(item.authorLogin)"
        ) {
          VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
            actionBar()
            DashboardDependencyStatusStrip(item: item)
          }
        }
        DashboardDependencyDetailSection(title: nil) {
          DashboardDependenciesDescriptionView(
            store: store,
            pullRequestID: item.pullRequestID,
            viewerCanUpdate: item.viewerCanUpdate,
            onCheckboxError: onDescriptionCheckboxError,
            onCheckboxUpdated: onDescriptionCheckboxUpdated
          )
        }
        .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardDependenciesDescription)
        if filesEnabled {
          DashboardDependencyDetailSection(title: "Files") {
            DashboardDependencyFilesSection(
              pullRequestID: item.pullRequestID,
              repositoryID: item.repositoryID
            )
          }
        }
        DashboardDependencyDetailSection(title: "Checks") {
          DashboardDependencyCheckList(
            checks: item.checks,
            showsProblemChecksOnly: $showsProblemChecksOnly,
            onRerunCheck: onRerunCheck
          )
        }
        DashboardDependencyDetailSection(title: "Activity") {
          DashboardDependencyActivitySummary(snapshot: activity)
        }
        DashboardDependencyDetailSection(title: "Reviews") {
          DashboardDependencyReviewList(reviews: item.reviews)
        }
        DashboardDependencyDetailSection(title: "Labels") {
          DashboardDependencyLabelStrip(labels: item.labels)
        }
        DashboardDependencyDetailSection(title: "Conversation") {
          DashboardDependencyConversationFeed(
            item: item,
            store: store,
            actionHandler: store.supervisorDecisionActionHandler()
          )
        }
      }
      .frame(maxWidth: dependenciesDetailMaxWidth, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .center)
      .task(
        id: DependencyUpdateBodyTaskKey(
          item: item, isDaemonOnline: store.connectionState == .online)
      ) {
        await store.prepareDependencyUpdateBody(for: item)
      }
    }
  }
}

struct DashboardDependencyDetailCard<Content: View>: View {
  let title: String
  let subtitle: String
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      Text(title)
        .scaledFont(.system(.title2, design: .rounded, weight: .semibold))
        .foregroundStyle(HarnessMonitorTheme.ink)
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
      Text(subtitle)
        .scaledFont(.callout.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      content()
    }
    .frame(maxWidth: dependenciesDetailMaxWidth, alignment: .leading)
    .padding(.bottom, HarnessMonitorTheme.spacingLG)
    .overlay(alignment: .bottom) {
      Divider().opacity(0.42)
    }
  }
}

struct DashboardDependencyDetailSection<Content: View>: View {
  let title: String?
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      if let title {
        Text(title)
          .scaledFont(.headline.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.ink)
      }
      content()
    }
    .frame(maxWidth: dependenciesDetailMaxWidth, alignment: .leading)
    .padding(.vertical, HarnessMonitorTheme.spacingLG)
    .overlay(alignment: .top) {
      Divider().opacity(0.34)
    }
  }
}
