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
              DashboardReviewFilesSection(
                pullRequestID: item.pullRequestID,
                repositoryID: item.repositoryID,
                onHideFilesForPR: { filesHiddenForCurrentPR = true }
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
          onJumpTo: { jumpTarget = $0 }
        ) {
          actionBar()
        }
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
}

/// Identifier for each detail-pane section. Used as the `.id()` anchor
/// for the Jump-to menu's `ScrollViewReader.scrollTo(_:anchor:)`.
enum DashboardReviewDetailSectionID: String, CaseIterable {
  case description
  case files
  case checks
  case activity
  case reviews
  case labels
  case conversation

  var menuTitle: String {
    switch self {
    case .description: "Description"
    case .files: "Files"
    case .checks: "Checks"
    case .activity: "Activity"
    case .reviews: "Reviews"
    case .labels: "Labels"
    case .conversation: "Conversation"
    }
  }
}

func dashboardReviewDetailJumpTargets(
  filesEnabled: Bool,
  filesHiddenForCurrentPR: Bool,
  showsConversation: Bool
) -> [DashboardReviewDetailSectionID] {
  // Files always anchors something — either the live section, the
  // global-disable placeholder, or the per-PR-dismissed placeholder.
  // Conversation only anchors when its section is present.
  DashboardReviewDetailSectionID.allCases.filter { id in
    switch id {
    case .conversation:
      return showsConversation
    default:
      return true
    }
  }
}

struct DashboardReviewFilesHiddenPlaceholder: View {
  let message: String
  let actionTitle: String
  let onAction: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: "eye.slash")
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Text(message)
        .scaledFont(.callout)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: HarnessMonitorTheme.spacingSM)
      Button(actionTitle, action: onAction)
        .controlSize(.small)
    }
  }
}

private struct DashboardReviewDetailHeader<Actions: View>: View {
  let item: ReviewItem
  let jumpTargets: [DashboardReviewDetailSectionID]
  let onJumpTo: (String) -> Void
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
        HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
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
          .harnessPlainButtonStyle()
          .disabled(pullRequestURL == nil)
          .help("Open pull request on GitHub")
          .accessibilityHint("Opens the pull request on GitHub")

          jumpToMenu
        }

        HStack(spacing: 0) {
          Text("\(item.repository)")
          Button {
            if let pullRequestURL {
              openURL(pullRequestURL)
            }
          } label: {
            Text("#\(item.number)")
          }
          .harnessPlainButtonStyle()
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
          .harnessPlainButtonStyle()
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
    // No bottom divider here — the first detail section's top divider
    // sits flush against the sticky header otherwise, doubling the
    // visual weight at the seam.
  }

  @ViewBuilder private var jumpToMenu: some View {
    Menu {
      ForEach(jumpTargets, id: \.self) { target in
        Button(target.menuTitle) {
          onJumpTo(target.rawValue)
        }
      }
    } label: {
      Image(systemName: "list.bullet.rectangle")
        .imageScale(.medium)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .contentShape(.rect)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Jump to section")
    .accessibilityLabel(Text("Jump to section"))
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
      Divider().opacity(0.40)
    }
  }
}
