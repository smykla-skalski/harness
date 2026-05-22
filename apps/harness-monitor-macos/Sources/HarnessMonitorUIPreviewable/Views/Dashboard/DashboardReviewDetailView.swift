import HarnessMonitorKit
import SwiftUI

struct DashboardReviewDetailView<Actions: View>: View {
  let item: ReviewItem
  let store: HarnessMonitorStore
  let activity: DashboardReviewActivitySnapshot
  let provenance: DashboardReviewsProvenanceSnapshot?
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
    provenance: DashboardReviewsProvenanceSnapshot? = nil,
    showsProblemChecksOnly: Binding<Bool> = .constant(false),
    onDescriptionCheckboxError: ((String) -> Void)? = nil,
    onDescriptionCheckboxUpdated: (() -> Void)? = nil,
    onRerunCheck: @escaping (ReviewCheck) -> Void = { _ in },
    @ViewBuilder actionBar: @escaping () -> Actions
  ) {
    self.item = item
    self.store = store
    self.activity = activity
    self.provenance = provenance
    _showsProblemChecksOnly = showsProblemChecksOnly
    self.onDescriptionCheckboxError = onDescriptionCheckboxError
    self.onDescriptionCheckboxUpdated = onDescriptionCheckboxUpdated
    self.onRerunCheck = onRerunCheck
    self.actionBar = actionBar
  }

  var body: some View {
    let viewModel = store.reviewTimelineViewModel(for: item.pullRequestID)
    ScrollView(.vertical) {
      LazyVStack(alignment: .leading, spacing: 18) {
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
      .padding(.horizontal, 24)
      .padding(.vertical, 24)
    }
    .scrollIndicators(.visible)
    .safeAreaInset(edge: .top, spacing: 0) {
      DashboardReviewDetailCard(
        title: item.title,
        subtitle: "\(item.repository)#\(item.number) · @\(item.authorLogin)"
      ) {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
          actionBar()
          DashboardReviewStatusStrip(item: item)
          if let provenance {
            DashboardReviewProvenanceMiniBar(snapshot: provenance)
          }
        }
      }
      .frame(maxWidth: reviewsDetailMaxWidth, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.horizontal, 24)
      .padding(.top, 24)
      .padding(.bottom, 8)
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
    .task(
      id: ReviewBodyTaskKey(
        item: item, isDaemonOnline: store.connectionState == .online)
    ) {
      await store.prepareReviewBody(for: item)
    }
    .environment(store)
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
          .scaledFont(.headline.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.ink)
      }
      content()
    }
    .frame(maxWidth: reviewsDetailMaxWidth, alignment: .leading)
    .padding(.vertical, HarnessMonitorTheme.spacingLG)
    .overlay(alignment: .top) {
      Divider().opacity(0.34)
    }
  }
}
