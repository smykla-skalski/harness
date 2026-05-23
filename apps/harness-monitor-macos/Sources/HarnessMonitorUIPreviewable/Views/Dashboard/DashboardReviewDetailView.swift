import HarnessMonitorKit
import SwiftUI

struct DashboardReviewDetailView<Actions: View>: View {
  let item: ReviewItem
  let store: HarnessMonitorStore
  let activity: DashboardReviewActivitySnapshot
  @Binding var showsProblemChecksOnly: Bool
  let onDescriptionCheckboxError: ((String) -> Void)?
  let onDescriptionCheckboxUpdated: (() -> Void)?
  let onRerunCheck: (ReviewCheck) -> Void
  @ViewBuilder let actionBar: () -> Actions

  @Environment(\.reviewsPreferences)
  private var reviewsPreferences

  private var filesEnabled: Bool {
    reviewsPreferences.snapshot.filesEnabled
  }

  init(
    item: ReviewItem,
    store: HarnessMonitorStore,
    activity: DashboardReviewActivitySnapshot,
    showsProblemChecksOnly: Binding<Bool> = .constant(false),
    onDescriptionCheckboxError: ((String) -> Void)? = nil,
    onDescriptionCheckboxUpdated: (() -> Void)? = nil,
    onRerunCheck: @escaping (ReviewCheck) -> Void = { _ in },
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
    let viewModel = store.reviewTimelineViewModel(for: item.pullRequestID)
    ScrollView(.vertical) {
      LazyVStack(alignment: .leading, spacing: 14) {
        DashboardReviewDetailSection(title: nil) {
          DashboardReviewsDescriptionView(
            store: store,
            pullRequestID: item.pullRequestID,
            viewerCanUpdate: item.viewerCanUpdate,
            onCheckboxError: onDescriptionCheckboxError,
            onCheckboxUpdated: onDescriptionCheckboxUpdated
          )
        }
        .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardReviewsDescription)
        if filesEnabled {
          DashboardReviewDetailSection(title: "Files") {
            DashboardReviewFilesSection(
              pullRequestID: item.pullRequestID,
              repositoryID: item.repositoryID
            )
          }
        }
        DashboardReviewDetailSection(title: "Checks") {
          DashboardReviewCheckList(
            checks: item.checks,
            showsProblemChecksOnly: $showsProblemChecksOnly,
            onRerunCheck: onRerunCheck
          )
        }
        DashboardReviewDetailSection(title: "Activity") {
          DashboardReviewActivitySummary(snapshot: activity)
        }
        DashboardReviewDetailSection(title: "Reviews") {
          DashboardReviewReviewList(reviews: item.reviews)
        }
        DashboardReviewDetailSection(title: "Labels") {
          DashboardReviewLabelStrip(labels: item.labels)
        }
        DashboardReviewDetailSection(title: "Conversation") {
          DashboardReviewConversationFeed(
            item: item,
            store: store,
            actionHandler: store.supervisorDecisionActionHandler(),
            showsComposer: false
          )
        }
      }
      .frame(maxWidth: reviewsDetailMaxWidth, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.horizontal, 28)
      .padding(.vertical, 18)
    }
    .scrollIndicators(.visible)
    .background(Color(nsColor: .windowBackgroundColor))
    .safeAreaInset(edge: .top, spacing: 0) {
      DashboardReviewDetailHeader(item: item) {
        actionBar()
      }
      .frame(maxWidth: reviewsDetailMaxWidth, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.horizontal, 28)
      .padding(.top, 18)
      .padding(.bottom, 10)
      .background(Color(nsColor: .windowBackgroundColor))
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      DashboardReviewCommentComposer(
        pullRequestID: item.pullRequestID,
        initialDraft: store.reviewCommentDraft(for: item.pullRequestID),
        viewerCanComment: viewModel.viewerCanComment,
        onDraftChange: { draft in
          store.scheduleReviewDraftWrite(item.pullRequestID, draft: draft)
        },
        onSend: { body in
          await store.postReviewComment(for: item, body: body)
        }
      )
      .frame(maxWidth: reviewsDetailMaxWidth, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .center)
      .background(Color(nsColor: .windowBackgroundColor))
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .task(
      id: ReviewBodyTaskKey(
        item: item, isDaemonOnline: store.connectionState == .online)
    ) {
      await store.prepareReviewBody(for: item)
    }
    .environment(store)
  }
}

private struct DashboardReviewDetailHeader<Actions: View>: View {
  let item: ReviewItem
  @ViewBuilder let actionBar: () -> Actions

  @Environment(\.openURL)
  private var openURL

  private var pullRequestURL: URL? {
    URL(string: item.url)
  }

  private var authorProfileURL: URL? {
    URL(string: "https://github.com/\(item.authorLogin)")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        Button {
          if let pullRequestURL {
            openURL(pullRequestURL)
          }
        } label: {
          Text(item.title)
            .scaledFont(.system(.title2, design: .rounded, weight: .semibold))
            .foregroundStyle(HarnessMonitorTheme.ink)
            .lineLimit(2)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .disabled(pullRequestURL == nil)
        .help("Open pull request on GitHub")
        .accessibilityHint("Opens the pull request on GitHub")

        HStack(spacing: 0) {
          Text("\(item.repository)")
          Button {
            if let pullRequestURL {
              openURL(pullRequestURL)
            }
          } label: {
            Text("#\(item.number)")
          }
          .buttonStyle(.plain)
          .disabled(pullRequestURL == nil)
          .help("Open pull request on GitHub")
          .accessibilityHint("Opens the pull request on GitHub")
          Text(" · @")
          Button {
            if let authorProfileURL {
              openURL(authorProfileURL)
            }
          } label: {
            Text(item.authorLogin)
          }
          .buttonStyle(.plain)
          .disabled(authorProfileURL == nil)
          .help("Open author profile on GitHub")
          .accessibilityHint("Opens the author profile on GitHub")
        }
        .scaledFont(.callout.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }

      actionBar()
      DashboardReviewStatusStrip(item: item)
      if item.requiresAttention {
        DashboardReviewAttentionSummary(item: item)
      }
    }
    .frame(maxWidth: reviewsDetailMaxWidth, alignment: .leading)
    .padding(.bottom, HarnessMonitorTheme.spacingMD)
    .overlay(alignment: .bottom) {
      Divider().opacity(0.24)
    }
  }
}

struct DashboardReviewDetailCard<Content: View>: View {
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
    .frame(maxWidth: reviewsDetailMaxWidth, alignment: .leading)
    .padding(.bottom, HarnessMonitorTheme.spacingLG)
    .overlay(alignment: .bottom) {
      Divider().opacity(0.42)
    }
  }
}

struct DashboardReviewDetailSection<Content: View>: View {
  let title: String?
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      if let title {
        Text(title)
          .scaledFont(.subheadline.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.ink)
      }
      content()
    }
    .frame(maxWidth: reviewsDetailMaxWidth, alignment: .leading)
    .padding(.vertical, HarnessMonitorTheme.spacingMD)
    .overlay(alignment: .top) {
      Divider().opacity(0.24)
    }
  }
}
