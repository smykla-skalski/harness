import AppKit
import HarnessMonitorKit
import SwiftUI

private let reviewGapScrollCompensationTolerance: CGFloat = 0.5

private struct DashboardReviewGapScrollCompensationRequest: Equatable {
  let id: UInt64
  let deltaY: CGFloat
}

struct DashboardReviewDetailView<Actions: View>: View {
  let item: ReviewItem
  let store: HarnessMonitorStore
  let activity: DashboardReviewActivitySnapshot
  let repositoryLabels: [ReviewRepositoryLabel]
  let viewerLogin: String?
  let filesAvailability: DashboardReviewsFilesModeAvailability
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
  @State private var gapScrollCompensationRequest: DashboardReviewGapScrollCompensationRequest?
  @State private var gapScrollCompensationRequestID: UInt64 = 0
  /// Pending jump target written by the header's Jump-to menu, read by
  /// the ScrollViewReader's onChange. Cleared back to nil after the
  /// scroll fires so re-selecting the same section still scrolls there.
  @State private var jumpTarget: String?

  init(
    item: ReviewItem,
    store: HarnessMonitorStore,
    activity: DashboardReviewActivitySnapshot,
    repositoryLabels: [ReviewRepositoryLabel] = [],
    viewerLogin: String? = nil,
    filesAvailability: DashboardReviewsFilesModeAvailability = .available,
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
    self.filesAvailability = filesAvailability
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
          DashboardReviewDetailSection(title: nil) {
            DashboardReviewOverviewSignalStrip(
              item: item,
              filesAvailability: filesAvailability,
              detailMode: $detailMode,
              showsSecondaryDetails: $showsSecondaryDetails,
              jumpTarget: $jumpTarget
            )
          }
          DashboardReviewDetailSection(title: "Activity") {
            if showsConversation {
              DashboardReviewConversationFeed(
                item: item,
                store: store,
                viewerLogin: viewerLogin,
                actionHandler: store.supervisorDecisionActionHandler(),
                onGapScrollCompensation: { deltaY in
                  requestGapScrollCompensation(deltaY)
                },
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
      .coordinateSpace(name: DashboardReviewDetailScrollCoordinateSpace.name)
      .background(
        DashboardReviewGapScrollCompensationApplicator(
          request: gapScrollCompensationRequest
        )
      )
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
          filesAvailability: filesAvailability,
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

  private func requestGapScrollCompensation(_ deltaY: CGFloat) {
    guard deltaY.isFinite, abs(deltaY) > reviewGapScrollCompensationTolerance else {
      return
    }
    gapScrollCompensationRequestID &+= 1
    gapScrollCompensationRequest = DashboardReviewGapScrollCompensationRequest(
      id: gapScrollCompensationRequestID,
      deltaY: deltaY
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
    .id(DashboardReviewDetailSectionID.moreDetails.rawValue)
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

private struct DashboardReviewGapScrollCompensationApplicator: NSViewRepresentable {
  let request: DashboardReviewGapScrollCompensationRequest?

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> DashboardReviewGapScrollCompensationApplicatorView {
    let view = DashboardReviewGapScrollCompensationApplicatorView()
    view.coordinator = context.coordinator
    return view
  }

  func updateNSView(
    _ view: DashboardReviewGapScrollCompensationApplicatorView,
    context: Context
  ) {
    if context.coordinator.updateRequest(request) {
      view.applyCompensationWhenReady()
    }
  }

  final class Coordinator {
    var request: DashboardReviewGapScrollCompensationRequest?
    private var appliedRequest: DashboardReviewGapScrollCompensationRequest?
    private weak var cachedScrollView: NSScrollView?

    func updateRequest(_ request: DashboardReviewGapScrollCompensationRequest?) -> Bool {
      guard self.request != request else {
        return false
      }
      self.request = request
      return request != nil
    }

    @MainActor
    func applyCompensation(from view: NSView) {
      guard let request, appliedRequest != request else {
        return
      }
      guard abs(request.deltaY) > reviewGapScrollCompensationTolerance else {
        appliedRequest = request
        return
      }
      guard let scrollView = resolvedScrollView(from: view) else {
        return
      }

      let targetOffset = SettingsScrollPersistencePolicy.restorationTargetOffset(
        storedOffset: SettingsScrollRestoreApplicator.currentOffset(in: scrollView)
          + request.deltaY,
        maxOffset: SettingsScrollRestoreApplicator.maxOffset(in: scrollView)
      )
      SettingsScrollRestoreApplicator.setOffset(
        targetOffset,
        in: scrollView,
        tolerance: reviewGapScrollCompensationTolerance
      )
      appliedRequest = request
    }

    @MainActor
    private func resolvedScrollView(from view: NSView) -> NSScrollView? {
      if let cachedScrollView,
        SettingsScrollRestoreApplicator.isRestorationCandidate(cachedScrollView, for: view)
      {
        return cachedScrollView
      }
      guard let scrollView = SettingsScrollRestoreApplicator.findNearestScrollView(from: view)
      else {
        return nil
      }
      cachedScrollView = scrollView
      return scrollView
    }
  }
}

private final class DashboardReviewGapScrollCompensationApplicatorView: NSView {
  weak var coordinator: DashboardReviewGapScrollCompensationApplicator.Coordinator?
  private var isApplyScheduled = false

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    applyCompensationWhenReady()
  }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    applyCompensationWhenReady()
  }

  func applyCompensationWhenReady() {
    guard !isApplyScheduled else { return }
    isApplyScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      isApplyScheduled = false
      coordinator?.applyCompensation(from: self)
    }
  }
}
