import HarnessMonitorKit
import SwiftUI

struct DashboardReviewDetailView<Actions: View>: View {
  let item: ReviewItem
  let store: HarnessMonitorStore
  let activity: DashboardReviewActivitySnapshot
  let repositoryLabels: [ReviewRepositoryLabel]
  let viewerLogin: String?
  @Binding var detailMode: DashboardReviewsDetailMode
  @Binding var showsProblemChecksOnly: Bool
  let onDescriptionCheckboxError: ((String) -> Void)?
  let onDescriptionCheckboxUpdated: (() -> Void)?
  let onRerunCheck: (ReviewCheck) -> Void
  let onReRequestReview: ((String) -> Void)?
  @ViewBuilder let actionBar: () -> Actions

  @Environment(\.reviewsPreferences)
  private var reviewsPreferences
  @Environment(\.fontScale)
  private var fontScale
  @State private var showsSecondaryDetails = false
  /// Pending jump target written by the header's Jump-to menu, read by
  /// the ScrollViewReader's onChange. Cleared back to nil after the
  /// scroll fires so re-selecting the same section still scrolls there.
  @State private var jumpTarget: String?

  private var filesEnabled: Bool {
    reviewsPreferences.snapshot.filesEnabled
  }

  init(
    item: ReviewItem,
    store: HarnessMonitorStore,
    activity: DashboardReviewActivitySnapshot,
    repositoryLabels: [ReviewRepositoryLabel] = [],
    viewerLogin: String? = nil,
    detailMode: Binding<DashboardReviewsDetailMode> = .constant(.overview),
    showsProblemChecksOnly: Binding<Bool> = .constant(false),
    onDescriptionCheckboxError: ((String) -> Void)? = nil,
    onDescriptionCheckboxUpdated: (() -> Void)? = nil,
    onRerunCheck: @escaping (ReviewCheck) -> Void = { _ in },
    onReRequestReview: ((String) -> Void)? = nil,
    @ViewBuilder actionBar: @escaping () -> Actions
  ) {
    self.item = item
    self.store = store
    self.activity = activity
    self.repositoryLabels = repositoryLabels
    self.viewerLogin = viewerLogin
    _detailMode = detailMode
    _showsProblemChecksOnly = showsProblemChecksOnly
    self.onDescriptionCheckboxError = onDescriptionCheckboxError
    self.onDescriptionCheckboxUpdated = onDescriptionCheckboxUpdated
    self.onRerunCheck = onRerunCheck
    self.onReRequestReview = onReRequestReview
    self.actionBar = actionBar
  }

  var body: some View {
    let viewModel = store.reviewTimelineViewModel(for: item.pullRequestID)
    let showsConversation = reviewsPreferences.snapshot.showActivityTimeline
    let jumpTargets = dashboardReviewDetailJumpTargets()
    ScrollViewReader { proxy in
      ScrollView(.vertical) {
        LazyVStack(alignment: .leading, spacing: 14) {
          DashboardReviewDetailSection(title: "Description") {
            DashboardReviewsDescriptionView(
              store: store,
              pullRequestID: item.pullRequestID,
              viewerCanUpdate: item.viewerCanUpdate,
              onCheckboxError: onDescriptionCheckboxError,
              onCheckboxUpdated: onDescriptionCheckboxUpdated,
              onRetryLoad: { [item] in
                Task { @MainActor in
                  await store.prepareReviewBody(for: item)
                }
              }
            )
          }
          .id(DashboardReviewDetailSectionID.description.rawValue)
          .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardReviewsDescription)
          DashboardReviewDetailSection(title: "Activity") {
            if showsConversation {
              DashboardReviewConversationFeed(
                item: item,
                store: store,
                actionHandler: store.supervisorDecisionActionHandler(),
                showsComposer: false
              )
            } else {
              DashboardReviewActivitySummary(snapshot: activity)
            }
          }
          .id(DashboardReviewDetailSectionID.activity.rawValue)
          DashboardReviewDetailSection(title: "Labels") {
            DashboardReviewLabelStrip(
              labels: item.labels,
              repositoryLabels: repositoryLabels
            )
          }
          .id(DashboardReviewDetailSectionID.labels.rawValue)
          secondaryDetailsSection(viewModel: viewModel)
        }
        .frame(maxWidth: reviewsDetailMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
      }
      .scrollIndicators(.visible)
      .background(Color(nsColor: .windowBackgroundColor))
      .onChange(of: jumpTarget) { _, target in
        guard let target else { return }
        withAnimation(.smooth(duration: 0.25)) {
          proxy.scrollTo(target, anchor: .top)
        }
        jumpTarget = nil
      }
      .safeAreaInset(edge: .top, spacing: 0) {
        DashboardReviewDetailHeader(
          item: item,
          detailMode: $detailMode,
          filesModeAvailable: filesEnabled,
          jumpTargets: jumpTargets,
          onJumpTo: { target in
            jumpTarget = target
          },
          actionBar: {
            actionBar()
          }
        )
        .frame(maxWidth: reviewsDetailMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .padding(.bottom, 10)
        .background(Color(nsColor: .windowBackgroundColor))
      }
      .background(Color(nsColor: .windowBackgroundColor))
      .task(
        id: ReviewBodyTaskKey(
          item: item, isDaemonOnline: store.connectionState == .online)
      ) {
        await store.prepareReviewBody(for: item)
      }
      .task(
        id: supplementaryTimelineLoadKey(
          isDaemonOnline: store.connectionState == .online,
          showsConversation: showsConversation
        )
      ) {
        guard showsSecondaryDetails, !showsConversation, store.connectionState == .online else {
          return
        }
        await store.prepareReviewTimeline(
          for: item,
          pageSize: reviewsPreferences.snapshot.normalizedTimelineInitialPageSize
        )
      }
      .onAppear {
        store.registerTimelineSubscription(pullRequestID: item.pullRequestID)
      }
      .onDisappear {
        store.unregisterTimelineSubscription(pullRequestID: item.pullRequestID)
      }
      .onChange(of: item.id) { oldValue, _ in
        showsSecondaryDetails = false
        // The structural identity stays stable while `item` updates to a new PR;
        // mirror the appear/disappear pair so the route guard tracks the
        // currently-visible PR, not the one that originally mounted the pane.
        store.unregisterTimelineSubscription(pullRequestID: oldValue)
        store.registerTimelineSubscription(pullRequestID: item.pullRequestID)
      }
      .font(HarnessMonitorTextSize.scaledFont(.body, by: fontScale))
      .environment(store)
    }
  }

  private func supplementaryTimelineLoadKey(
    isDaemonOnline: Bool,
    showsConversation: Bool
  ) -> ReviewTimelineTaskKey {
    ReviewTimelineTaskKey(
      item: item,
      isDaemonOnline: isDaemonOnline,
      pageSize: reviewsPreferences.snapshot.normalizedTimelineInitialPageSize,
      isActive: showsSecondaryDetails && !showsConversation
    )
  }

  @ViewBuilder
  private func commentComposerSection(
    viewModel: ReviewTimelineViewModel
  ) -> some View {
    DashboardReviewCommentComposer(
      pullRequestID: item.pullRequestID,
      initialDraft: store.reviewCommentDraft(for: item.pullRequestID),
      viewerCanComment: viewModel.viewerCanComment,
      fontScale: fontScale,
      viewerLogin: viewerLogin,
      onDraftChange: { draft in
        store.scheduleReviewDraftWrite(item.pullRequestID, draft: draft)
      },
      onSend: { body in
        await store.postReviewComment(for: item, body: body)
      }
    )
    // Per-PR `@State` reset for the composer-owned draft/preview/error
    // state. Tying the composer's identity to the pull request id makes
    // SwiftUI re-init that local state when the user navigates to a
    // different PR.
    .id(item.pullRequestID)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func secondaryDetailsSection(
    viewModel: ReviewTimelineViewModel
  ) -> some View {
    DashboardReviewDetailSection(title: nil) {
      DisclosureGroup(isExpanded: $showsSecondaryDetails) {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingLG) {
          secondaryDetailsBlock(title: "Checks") {
            DashboardReviewCheckList(
              checks: item.checks,
              showsProblemChecksOnly: $showsProblemChecksOnly,
              onRerunCheck: onRerunCheck
            )
          }
          secondaryDetailsBlock(title: "Reviews") {
            DashboardReviewReviewList(
              reviews: item.reviews,
              viewerLogin: viewerLogin,
              canReRequestReview: item.viewerCanUpdate && onReRequestReview != nil,
              onReRequestReview: onReRequestReview
            )
          }
          secondaryDetailsBlock(title: "Comment") {
            commentComposerSection(viewModel: viewModel)
          }
        }
        .padding(.top, HarnessMonitorTheme.spacingMD)
      } label: {
        Text("More details")
          .scaledFont(.subheadline.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.ink)
      }
      .accessibilityLabel("More details")
    }
  }

  @ViewBuilder
  private func secondaryDetailsBlock<Content: View>(
    title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text(title)
        .scaledFont(.subheadline.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.ink)
      content()
    }
  }
}
