import AppKit
import Foundation
import HarnessMonitorKit
import SwiftUI

/// Single-row presentation of a pull request inside the Reviews route content
/// pane.
///
/// Structure (top to bottom):
/// 1. Title row: status icon · optional avatar chip · wrapped title
/// 2. Metadata row: optional `#N · age` identity plus repository text on the
///    left, with pills trailing only when that identity is visible
/// 3. Optional labels strip: muted chips for `item.labels`
///
/// Pinned rows render a soft `.accent` background tint so they stay visible
/// without needing extra chrome next to the title (the pinned section header
/// already names the section).
///
/// Optional rows now grow the row naturally, while a deterministic
/// `minHeight` floor keeps the existing padding for one-line content and
/// explicit title newlines without adding geometry-driven state. Soft-wrapped
/// titles, pill rows, and label strips therefore take only the height they
/// actually render. Metadata and labels are indented from the title's leading
/// edge so the leading status/author chrome aligns only with the title block.
/// Accessibility uses `children: .contain` (item 31) so the status icon stays
/// an individually-focusable element with its own label (items 32 / 67).
struct DashboardReviewListRow: View {
  let item: ReviewItem
  let showsRepository: Bool
  let isSelected: Bool
  let isPinned: Bool
  let isRefreshing: Bool
  let actionTitle: String?
  let updatedLabel: String
  let repositoryLabels: [ReviewRepositoryLabel]
  let showsAvatars: Bool
  let showsLabels: Bool
  let showsLineCounters: Bool
  let showsPullRequestNumber: Bool
  let showsPullRequestAge: Bool
  let wrapsTitle: Bool
  let titleMaximumLines: Int
  let hidesSemanticPrefixesInTitle: Bool
  let secondaryText: String?
  let displayTitle: String
  let pullRequestNumberText: String
  let inlineIdentityAndAge: String
  private let displayTitleInlines: [HarnessMarkdownInline]?
  private let attentionBadges: DashboardReviewAttentionBadges
  private let requiredFailedCheckNames: DashboardReviewVisibleRequiredFailedCheckNames?
  private let inlineIdentityAndAgeHelp: String
  let titleAccessibilityText: String

  @Environment(\.fontScale)
  private var fontScale

  @State private var appKitSelectionIsActive: Bool
  @State private var isHovered: Bool = false
  @FocusState private var isFocused: Bool

  let leadingStatusIndicatorWidth: CGFloat = 18
  let authorChipWidth: CGFloat = 16

  @ScaledMetric(relativeTo: .callout)
  var titleLineHeight: CGFloat = 18
  @ScaledMetric(relativeTo: .caption)
  var captionLineHeight: CGFloat = 14
  @ScaledMetric(relativeTo: .caption)
  var statusPillLineHeight: CGFloat = 20
  @ScaledMetric(relativeTo: .caption)
  var labelStripHeight: CGFloat = 22

  var rowVerticalSpacing: CGFloat { HarnessMonitorTheme.spacingSM }

  init(
    item: ReviewItem,
    showsRepository: Bool,
    isSelected: Bool = false,
    isPinned: Bool = false,
    isRefreshing: Bool,
    actionTitle: String?,
    updatedLabel: String,
    repositoryLabels: [ReviewRepositoryLabel] = [],
    showsAvatars: Bool = true,
    showsLabels: Bool = true,
    showsLineCounters: Bool = true,
    showsPullRequestNumber: Bool = true,
    showsPullRequestAge: Bool = true,
    wrapsTitle: Bool = true,
    titleMaximumLines: Int = DashboardReviewsPreferences.defaultRowTitleMaximumLines,
    hidesSemanticPrefixesInTitle: Bool = false
  ) {
    self.item = item
    self.showsRepository = showsRepository
    self.isSelected = isSelected
    self.isPinned = isPinned
    self.isRefreshing = isRefreshing
    self.actionTitle = actionTitle
    self.updatedLabel = updatedLabel
    self.repositoryLabels = repositoryLabels
    self.showsAvatars = showsAvatars
    self.showsLabels = showsLabels
    self.showsLineCounters = showsLineCounters
    self.showsPullRequestNumber = showsPullRequestNumber
    self.showsPullRequestAge = showsPullRequestAge
    self.wrapsTitle = wrapsTitle
    self.titleMaximumLines = titleMaximumLines
    self.hidesSemanticPrefixesInTitle = hidesSemanticPrefixesInTitle
    secondaryText = showsRepository ? item.repository : nil
    let displayTitle = dashboardReviewDisplayedTitle(
      item.title,
      hidesSemanticPrefix: hidesSemanticPrefixesInTitle
    )
    self.displayTitle = displayTitle
    let displayTitleInlines = dashboardReviewInlineTitleInlines(displayTitle)
    self.displayTitleInlines = displayTitleInlines
    titleAccessibilityText =
      displayTitleInlines.map(dashboardReviewInlineTitlePlainText) ?? displayTitle
    let pullRequestNumberText = showsPullRequestNumber ? "#\(item.number)" : ""
    self.pullRequestNumberText = pullRequestNumberText
    let inlineLabels = Self.makeInlineIdentityAndAgeLabels(
      pullRequestNumberText: pullRequestNumberText,
      showsAge: showsPullRequestAge,
      updatedLabel: updatedLabel
    )
    inlineIdentityAndAge = inlineLabels.visible
    inlineIdentityAndAgeHelp = inlineLabels.help
    attentionBadges = Self.dashboardReviewAttentionBadgeKinds(for: item)
    requiredFailedCheckNames = Self.makeVisibleRequiredFailedCheckNames(for: item)
    _appKitSelectionIsActive = State(initialValue: isSelected)
  }

  var body: some View {
    let minimumRowHeight = rowMinimumHeight(
      titleLineCount: estimatedTitleLineCount,
      showsMetadataLine: showsMetadataLine,
      showsLabels: showsLabelsStrip
    )

    VStack(alignment: .leading, spacing: rowVerticalSpacing) {
      titleBlock

      if showsMetadataLine {
        metadataLine
          .padding(.leading, titleContentLeadingInset)
      }

      if showsLabelsStrip {
        DashboardReviewListRowLabelsStrip(
          labels: item.labels,
          repositoryLabels: repositoryLabels,
          usesSelectedBackgroundContrast: isSelected
        )
        .padding(.leading, titleContentLeadingInset)
      }
    }
    .padding(.horizontal, DashboardReviewsVisualMetrics.reviewRowHorizontalPadding)
    .padding(.vertical, DashboardReviewsVisualMetrics.reviewRowVerticalPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(minHeight: minimumRowHeight, alignment: .topLeading)
    .listRowBackground(rowChromeBackground)
    .background {
      DashboardReviewRowSelectionProbe(isSelected: $appKitSelectionIsActive)
    }
    .contentShape(Rectangle())
    .scaleEffect(isFocused ? 0.995 : 1.0)
    .onHover { hovering in
      isHovered = hovering
    }
    .accessibilityElement(children: .contain)
  }

  // MARK: - Title subviews

  @ViewBuilder var titleBlock: some View {
    HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
      leadingStatusIndicator
        .frame(height: titleLineHeight, alignment: .center)
      if showsAvatars {
        DashboardReviewListRowAuthorChip(
          login: item.authorLogin,
          avatarURL: item.authorAvatarURL
        )
        .frame(height: titleLineHeight, alignment: .center)
      }
      titleLine
        .layoutPriority(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder private var titleLine: some View {
    titleLineText
      .lineLimit(effectiveTitleMaximumLines)
      .truncationMode(.tail)
      .fixedSize(horizontal: false, vertical: true)
      .help(item.title)
      .accessibilityLabel(titleAccessibilityLabel)
      .focused($isFocused)
  }

  @ViewBuilder private var titleLineText: some View {
    if let displayTitleInlines {
      Text(
        HarnessMarkdownInlineRenderer.attributedString(
          from: displayTitleInlines,
          style: titleInlineStyle
        )
      )
    } else {
      Text(displayTitle)
        .scaledFont(.callout)
        .foregroundStyle(primaryTextColor)
    }
  }

  @ViewBuilder var leadingStatusIndicator: some View {
    ZStack {
      if isRefreshing {
        ProgressView()
          .controlSize(.small)
          .tint(statusIndicatorColor)
          .accessibilityLabel(progressAccessibilityLabel)
          .transition(.opacity)
      } else {
        Image(systemName: item.statusSystemImage)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(statusIndicatorColor)
          .opacity(item.viewerCanUpdate ? 1 : selectedIconDimmedOpacity)
          .accessibilityLabel(item.statusAccessibilityLabel)
          .transition(.opacity)
      }
    }
    .frame(width: leadingStatusIndicatorWidth, alignment: .center)
    .help(statusIndicatorHelp)
  }

  var progressAccessibilityLabel: String {
    if let actionTitle, !actionTitle.isEmpty {
      "\(actionTitle) pull request"
    } else {
      "Working on pull request"
    }
  }

  var statusIndicatorHelp: String {
    if !item.viewerCanUpdate {
      return "You don't have permission to update this PR"
    }
    return item.statusAccessibilityLabel
  }

  private var titleInlineStyle: HarnessMarkdownInlineRenderStyle {
    HarnessMarkdownInlineRenderStyle(
      font: HarnessMonitorTextSize.scaledFont(.callout, by: fontScale),
      codeFont: HarnessMonitorTextSize.scaledFont(
        .callout.monospaced(),
        by: fontScale
      ),
      colors: usesSelectedBackgroundContrast ? .selectedRow : .default
    )
  }

  // MARK: - Metadata subviews

  @ViewBuilder var metadataLine: some View {
    HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
      if !inlineIdentityAndAge.isEmpty {
        Text(inlineIdentityAndAge)
          .monospacedDigit()
          .scaledFont(.caption)
          .foregroundStyle(secondaryTextColor)
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)
          .help(inlineIdentityAndAgeHelp)
          .accessibilityLabel(inlineIdentityAndAgeHelp)
      }

      if let secondary = secondaryText {
        if !inlineIdentityAndAge.isEmpty {
          Text("·")
            .scaledFont(.caption)
            .foregroundStyle(secondaryTextColor)
            .accessibilityHidden(true)
        }
        Text(secondary)
          .scaledFont(.caption)
          .foregroundStyle(secondaryTextColor)
          .lineLimit(1)
          .truncationMode(.middle)
          .help(secondary)
      }

      if shouldRightAlignMetadataPills {
        Spacer(minLength: HarnessMonitorTheme.spacingSM)
      }

      if metadataLineHasPillChrome {
        metadataPillContent
          .layoutPriority(shouldRightAlignMetadataPills ? 0 : 1)
      }
    }
  }

  var metadataLineHasPillChrome: Bool {
    item.isDraft
      || !item.reviews.isEmpty
      || !attentionBadges.isEmpty
      || showsChangePill
  }

  var metadataLineIdealHeight: CGFloat {
    metadataLineHasPillChrome ? statusPillLineHeight : captionLineHeight
  }

  var showsMetadataLine: Bool {
    secondaryText != nil
      || !inlineIdentityAndAge.isEmpty
      || metadataLineHasPillChrome
  }

  @ViewBuilder var metadataPillContent: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      ForEach(attentionBadges.kinds) { kind in
        metadataBadge(kind)
      }

      if item.isDraft {
        DashboardReviewStatusPill(
          label: "Draft",
          tint: HarnessMonitorTheme.secondaryInk,
          systemImage: "pencil.tip.crop.circle",
          isQuiet: true,
          usesSelectedBackgroundContrast: usesSelectedBackgroundContrast
        )
      }

      DashboardReviewListRowReviewerSummary(
        item: item,
        usesSelectedBackgroundContrast: usesSelectedBackgroundContrast
      )

      if showsChangePill {
        DashboardReviewChangePill(
          additions: item.additions,
          deletions: item.deletions,
          style: .compact,
          usesSelectedBackgroundContrast: usesSelectedBackgroundContrast
        )
      }
    }
  }

  private func metadataBadge(_ kind: DashboardReviewAttentionBadgeKind) -> some View {
    DashboardReviewStatusPill(
      label: kind.label,
      tint: kind.tint,
      systemImage: kind.systemImage,
      isQuiet: true,
      usesSelectedBackgroundContrast: usesSelectedBackgroundContrast,
      help: metadataBadgeHelp(for: kind)
    )
  }

  private func metadataBadgeHelp(for kind: DashboardReviewAttentionBadgeKind) -> String {
    guard kind == .requiredChecks, let requiredFailedCheckNames else { return kind.label }
    let visibleNames = requiredFailedCheckNames.visible.joined(separator: ", ")
    guard !visibleNames.isEmpty else { return kind.label }
    if requiredFailedCheckNames.overflow > 0 {
      return "Required checks: \(visibleNames), +\(requiredFailedCheckNames.overflow) more"
    }
    return "Required checks: \(visibleNames)"
  }

  // MARK: - Row chrome

  private var usesSelectedBackgroundContrast: Bool {
    appKitSelectionIsActive
  }

  var rowBackgroundColor: Color {
    if isHovered {
      HarnessMonitorTheme.ink.opacity(0.05)
    } else if isPinned {
      HarnessMonitorTheme.accent.opacity(0.05)
    } else {
      Color.clear
    }
  }

  private var primaryTextColor: Color {
    if usesSelectedBackgroundContrast {
      Color(nsColor: .alternateSelectedControlTextColor)
    } else {
      HarnessMonitorTheme.ink
    }
  }

  private var secondaryTextColor: Color {
    if usesSelectedBackgroundContrast {
      Color(nsColor: .alternateSelectedControlTextColor)
    } else {
      HarnessMonitorTheme.secondaryInk
    }
  }

  private var statusIndicatorColor: Color {
    if usesSelectedBackgroundContrast {
      Color(nsColor: .alternateSelectedControlTextColor)
    } else {
      item.statusTint
    }
  }

  private var selectedIconDimmedOpacity: Double {
    usesSelectedBackgroundContrast ? 0.74 : 0.4
  }

  var rowChromeBackground: some View {
    ZStack {
      rowBackgroundColor
      VStack(spacing: 0) {
        Spacer(minLength: 0)
        Rectangle()
          .fill(Color(nsColor: .separatorColor))
          .frame(height: 1)
      }
    }
  }
}

struct DashboardReviewVisibleRequiredFailedCheckNames {
  let visible: ArraySlice<String>
  let overflow: Int
}

private struct DashboardReviewRowSelectionProbe: NSViewRepresentable {
  @Binding var isSelected: Bool

  func makeNSView(context: Context) -> DashboardReviewRowSelectionProbeView {
    DashboardReviewRowSelectionProbeView { isSelected in
      context.coordinator.updateSelection(isSelected)
    }
  }

  func updateNSView(_ nsView: DashboardReviewRowSelectionProbeView, context: Context) {
    context.coordinator.selection = $isSelected
    nsView.onSelectionChange = { isSelected in
      context.coordinator.updateSelection(isSelected)
    }
    nsView.attachToRowViewIfNeeded()
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(selection: $isSelected)
  }

  static func dismantleNSView(
    _ nsView: DashboardReviewRowSelectionProbeView,
    coordinator: Coordinator
  ) {
    nsView.detach()
  }

  final class Coordinator {
    var selection: Binding<Bool>

    init(selection: Binding<Bool>) {
      self.selection = selection
    }

    func updateSelection(_ isSelected: Bool) {
      guard selection.wrappedValue != isSelected else { return }
      selection.wrappedValue = isSelected
    }
  }
}

private final class DashboardReviewRowSelectionProbeView: NSView {
  var onSelectionChange: (Bool) -> Void

  private weak var observedRowView: NSTableRowView?
  private var selectionObservation: NSKeyValueObservation?
  private var lastAppliedSelectionState: Bool?

  init(onSelectionChange: @escaping (Bool) -> Void) {
    self.onSelectionChange = onSelectionChange
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  override func viewWillMove(toSuperview newSuperview: NSView?) {
    if newSuperview == nil {
      detach()
    }
    super.viewWillMove(toSuperview: newSuperview)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    attachToRowViewIfNeeded()
  }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    attachToRowViewIfNeeded()
  }

  func attachToRowViewIfNeeded() {
    guard
      window != nil,
      let rowView = enclosingTableRowView()
    else {
      detach()
      return
    }

    guard observedRowView !== rowView else {
      applySelectionState()
      return
    }

    detach()
    observedRowView = rowView
    selectionObservation = rowView.observe(\.isSelected, options: [.initial, .new]) {
      [weak self] _, _ in
      MainActor.assumeIsolated {
        self?.applySelectionState()
      }
    }
  }

  func detach() {
    selectionObservation?.invalidate()
    selectionObservation = nil
    observedRowView = nil
    lastAppliedSelectionState = nil
  }

  private func applySelectionState() {
    let nextSelectionState = observedRowView?.isSelected ?? false
    guard lastAppliedSelectionState != nextSelectionState else { return }
    lastAppliedSelectionState = nextSelectionState
    onSelectionChange(nextSelectionState)
  }

  private func enclosingTableRowView() -> NSTableRowView? {
    var view = superview
    var depth = 0
    while let current = view, depth < 12 {
      if let rowView = current as? NSTableRowView {
        return rowView
      }
      view = current.superview
      depth += 1
    }
    return nil
  }
}
