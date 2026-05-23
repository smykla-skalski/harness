import HarnessMonitorKit
import SwiftUI

struct DashboardReviewDetailView<Actions: View>: View {
  let item: ReviewItem
  let store: HarnessMonitorStore
  let activity: DashboardReviewActivitySnapshot
  let repositoryLabels: [ReviewRepositoryLabel]
  let viewerLogin: String?
  @Binding var showsProblemChecksOnly: Bool
  let onDescriptionCheckboxError: ((String) -> Void)?
  let onDescriptionCheckboxUpdated: (() -> Void)?
  let onRerunCheck: (ReviewCheck) -> Void
  let onReRequestReview: ((String) -> Void)?
  let onOpenFilesMode: () -> Void
  @ViewBuilder let actionBar: () -> Actions

  @Environment(\.reviewsPreferences)
  private var reviewsPreferences
  @Environment(\.fontScale)
  private var fontScale
  /// Per-PR escape hatch from the cloning empty-state. When the daemon
  /// is taking a long time to clone, the user can dismiss the Files
  /// section for this PR without touching the global Files-enabled
  /// preference. Resets when the user navigates to a different PR.
  @State private var filesHiddenForCurrentPR: Bool = false
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
    showsProblemChecksOnly: Binding<Bool> = .constant(false),
    onDescriptionCheckboxError: ((String) -> Void)? = nil,
    onDescriptionCheckboxUpdated: (() -> Void)? = nil,
    onRerunCheck: @escaping (ReviewCheck) -> Void = { _ in },
    onReRequestReview: ((String) -> Void)? = nil,
    onOpenFilesMode: @escaping () -> Void = {},
    @ViewBuilder actionBar: @escaping () -> Actions
  ) {
    self.item = item
    self.store = store
    self.activity = activity
    self.repositoryLabels = repositoryLabels
    self.viewerLogin = viewerLogin
    _showsProblemChecksOnly = showsProblemChecksOnly
    self.onDescriptionCheckboxError = onDescriptionCheckboxError
    self.onDescriptionCheckboxUpdated = onDescriptionCheckboxUpdated
    self.onRerunCheck = onRerunCheck
    self.onReRequestReview = onReRequestReview
    self.onOpenFilesMode = onOpenFilesMode
    self.actionBar = actionBar
  }

  var body: some View {
    let viewModel = store.reviewTimelineViewModel(for: item.pullRequestID)
    let showsConversation = reviewsPreferences.snapshot.showActivityTimeline
    let jumpTargets = dashboardReviewDetailJumpTargets(
      filesEnabled: filesEnabled,
      filesHiddenForCurrentPR: filesHiddenForCurrentPR,
      showsConversation: showsConversation
    )
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
          if filesEnabled, !filesHiddenForCurrentPR {
            DashboardReviewDetailSection(title: "Files") {
              DashboardReviewFilesOverviewSummary(
                item: item,
                store: store,
                pullRequestID: item.pullRequestID,
                repositoryID: item.repositoryID,
                onOpenFiles: onOpenFilesMode
              )
            }
            .id(DashboardReviewDetailSectionID.files.rawValue)
          } else if !filesEnabled {
            DashboardReviewDetailSection(title: "Files") {
              DashboardReviewFilesHiddenPlaceholder(
                message: "Files are disabled in Reviews preferences.",
                actionTitle: "Enable Files"
              ) {
                reviewsPreferences.update { $0.filesEnabled = true }
              }
            }
            .id(DashboardReviewDetailSectionID.files.rawValue)
          } else {
            DashboardReviewDetailSection(title: "Files") {
              DashboardReviewFilesHiddenPlaceholder(
                message: "Files are hidden for this PR while the daemon clones in the background.",
                actionTitle: "Show Files"
              ) {
                filesHiddenForCurrentPR = false
              }
            }
            .id(DashboardReviewDetailSectionID.files.rawValue)
          }
          DashboardReviewDetailSection(title: "Checks") {
            DashboardReviewCheckList(
              checks: item.checks,
              showsProblemChecksOnly: $showsProblemChecksOnly,
              onRerunCheck: onRerunCheck
            )
          }
          .id(DashboardReviewDetailSectionID.checks.rawValue)
          DashboardReviewDetailSection(title: "Activity") {
            DashboardReviewActivitySummary(snapshot: activity)
          }
          .id(DashboardReviewDetailSectionID.activity.rawValue)
          DashboardReviewDetailSection(title: "Reviews") {
            DashboardReviewReviewList(
              reviews: item.reviews,
              viewerLogin: viewerLogin,
              canReRequestReview: item.viewerCanUpdate && onReRequestReview != nil,
              onReRequestReview: onReRequestReview
            )
          }
          .id(DashboardReviewDetailSectionID.reviews.rawValue)
          DashboardReviewDetailSection(title: "Labels") {
            DashboardReviewLabelStrip(
              labels: item.labels,
              repositoryLabels: repositoryLabels
            )
          }
          .id(DashboardReviewDetailSectionID.labels.rawValue)
          if showsConversation {
            DashboardReviewDetailSection(title: "Conversation") {
              DashboardReviewConversationFeed(
                item: item,
                store: store,
                actionHandler: store.supervisorDecisionActionHandler(),
                showsComposer: false
              )
            }
            .id(DashboardReviewDetailSectionID.conversation.rawValue)
          }
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
          jumpTargets: jumpTargets,
          onJumpTo: { target in
            if target == DashboardReviewDetailSectionID.files.rawValue {
              onOpenFilesMode()
            } else {
              jumpTarget = target
            }
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
      .safeAreaInset(edge: .bottom, spacing: 12) {
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
        // Per-PR `@State` reset — see DashboardReviewCommentComposer's
        // `isCollapsed` declaration. Tying the composer's identity to
        // the pull request id makes SwiftUI re-init its state when the
        // user navigates to a different PR.
        .id(item.pullRequestID)
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
      .task(id: filesThreadLoadKey(isDaemonOnline: store.connectionState == .online)) {
        guard filesEnabled, store.connectionState == .online else { return }
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
        filesHiddenForCurrentPR = false
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

  private func filesThreadLoadKey(isDaemonOnline: Bool) -> String {
    [
      item.pullRequestID,
      filesEnabled.description,
      isDaemonOnline.description,
      "\(reviewsPreferences.snapshot.normalizedTimelineInitialPageSize)",
    ].joined(separator: ":")
  }
}
