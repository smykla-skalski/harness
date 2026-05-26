import AppKit
import HarnessMonitorKit
import SwiftUI

/// Visual derivation for the repository section header.
///
/// Pure value type: given the scheduler-derived inputs, returns the exact
/// status-cluster variant the header should render. Lets the visual-state
/// matrix be unit-tested without touching SwiftUI.
public enum DashboardReviewsRepositorySectionHeaderStatus: Equatable {
  case syncing
  case error(message: String)
  case lastSynced(date: Date)
  case neverSynced

  public static func derive(
    isSyncing: Bool,
    lastSyncedAt: Date?,
    errorMessage: String?
  ) -> Self {
    if isSyncing {
      return .syncing
    }
    if let errorMessage {
      return .error(message: errorMessage)
    }
    if let lastSyncedAt {
      return .lastSynced(date: lastSyncedAt)
    }
    return .neverSynced
  }
}

/// Whether the retry control should be visible for the current state.
///
/// Retry stays visible while a repository is syncing because the previous
/// failure is still the most recent outcome the user has any reason to act on;
/// it's only marked disabled so the click is inert until the in-flight tick
/// completes.
public func dashboardReviewsRepositorySectionHeaderShouldShowRetry(
  errorMessage: String?
) -> Bool {
  errorMessage != nil
}

public func dashboardReviewsRepositorySectionHeaderRetryIsEnabled(
  isSyncing: Bool
) -> Bool {
  !isSyncing
}

public func dashboardReviewsRepositorySectionHeaderRelativeSyncDisplayLabel(
  date: Date,
  referenceDate: Date = .now
) -> String {
  dashboardReviewsRepositorySectionHeaderRelativeSyncDescription(
    date: date,
    referenceDate: referenceDate
  ).display
}

public func dashboardReviewsRepositorySectionHeaderRelativeSyncAccessibilityLabel(
  date: Date,
  referenceDate: Date = .now
) -> String {
  dashboardReviewsRepositorySectionHeaderRelativeSyncDescription(
    date: date,
    referenceDate: referenceDate
  ).accessibility
}

/// Accessibility label for the busy-progress indicator. Carries the
/// `X working` count that the old trailing pill used to render visually.
public func dashboardReviewsRepositorySectionHeaderBusyAccessibilityLabel(
  busyPullRequestCount: Int
) -> String {
  busyPullRequestCount == 1
    ? "1 pull request updating"
    : "\(busyPullRequestCount) pull requests updating"
}

@MainActor
struct DashboardReviewsRepositorySectionHeader: View {
  let repository: String
  let itemCount: Int
  let busyPullRequestCount: Int
  let isCollapsed: Bool
  let isPinned: Bool
  let scheduler: DashboardReviewsScheduler
  let onToggleCollapse: () -> Void
  let onTogglePin: () -> Void
  let onRetryRepository: () -> Void

  var body: some View {
    let isSyncing = scheduler.repositoriesInFlight.contains(repository)
    let state = scheduler.states[repository]
    let lastSyncedAt = state?.lastSyncedAt
    let errorMessage = state?.lastErrorMessage
    let status = DashboardReviewsRepositorySectionHeaderStatus.derive(
      isSyncing: isSyncing,
      lastSyncedAt: lastSyncedAt,
      errorMessage: errorMessage
    )
    DashboardReviewsSectionHeaderChrome(isPinnedFamily: isPinned) {
      Button(action: onToggleCollapse) {
        HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
          HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
              .font(.caption.weight(.semibold))
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              .frame(width: 12, alignment: .center)
            repositoryNameLabel
          }
          Spacer(minLength: HarnessMonitorTheme.spacingSM)
          syncStatusCluster(status: status, isSyncing: isSyncing, errorMessage: errorMessage)
          countSeparator
          itemCountText
        }
        .contentShape(.rect)
      }
      .buttonStyle(.borderless)
    }
    .contextMenu {
      Button(isPinned ? "Unpin Repository" : "Pin Repository") {
        onTogglePin()
      }
    }
  }

  /// Renders the `owner/repo` slug with the owner prefix muted so the repo
  /// name stays the legible anchor. When users group by repository under a
  /// single owner — the common case — the repeated `smykla-skalski/` recedes
  /// into the chrome and the eye lands on the unique repo segment.
  @ViewBuilder private var repositoryNameLabel: some View {
    let parts = repository.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
      if isPinned {
        Image(systemName: "pin.fill")
          .imageScale(.small)
          .foregroundStyle(HarnessMonitorTheme.accent)
          .help("Pinned to top")
          .accessibilityLabel("Pinned")
      }
      if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty {
        HStack(spacing: 0) {
          Text("\(parts[0])/")
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          Text(parts[1])
            .foregroundStyle(HarnessMonitorTheme.ink)
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(repository)
      } else {
        Text(repository)
          .foregroundStyle(HarnessMonitorTheme.ink)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }
  }

  @ViewBuilder
  private func syncStatusCluster(
    status: DashboardReviewsRepositorySectionHeaderStatus,
    isSyncing: Bool,
    errorMessage: String?
  ) -> some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingXS) {
      statusView(for: status)
      if busyPullRequestCount > 0 {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel(
            dashboardReviewsRepositorySectionHeaderBusyAccessibilityLabel(
              busyPullRequestCount: busyPullRequestCount
            )
          )
      }
      if dashboardReviewsRepositorySectionHeaderShouldShowRetry(errorMessage: errorMessage) {
        retryButton(errorMessage: errorMessage ?? "", isSyncing: isSyncing)
      }
    }
  }

  @ViewBuilder
  private func statusView(
    for status: DashboardReviewsRepositorySectionHeaderStatus
  ) -> some View {
    switch status {
    case .syncing:
      ProgressView()
        .controlSize(.small)
        .accessibilityLabel("Syncing \(repository)")
    case .error(let message):
      DashboardReviewsRepositoryHeaderPill(
        title: "Error",
        systemImage: "exclamationmark.triangle",
        accessibilityLabel: "Last sync failed: \(message)"
      )
      .help(message)
    case .lastSynced(let date):
      // Renders without the refresh glyph so the per-group timestamp reads
      // as quiet metadata rather than a second instance of the provenance
      // bar's refresh action — the icon was decorative, not a button.
      Text(
        verbatim: dashboardReviewsRepositorySectionHeaderRelativeSyncDisplayLabel(
          date: date
        )
      )
      .scaledFont(.caption)
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      .lineLimit(1)
      .help(
        "Last synced \(dashboardReviewsRepositorySectionHeaderRelativeSyncAccessibilityLabel(date: date))"
      )
      .accessibilityLabel(
        "Last synced \(dashboardReviewsRepositorySectionHeaderRelativeSyncAccessibilityLabel(date: date))"
      )
    case .neverSynced:
      DashboardReviewsRepositoryHeaderPill(
        title: "Never synced",
        accessibilityLabel: "Never synced"
      )
    }
  }

  private func retryButton(errorMessage: String, isSyncing: Bool) -> some View {
    let enabled = dashboardReviewsRepositorySectionHeaderRetryIsEnabled(isSyncing: isSyncing)
    return Button(action: onRetryRepository) {
      Image(systemName: "arrow.clockwise.circle")
        .imageScale(.medium)
    }
    .buttonStyle(.borderless)
    .disabled(!enabled)
    .help("Retry \(repository): \(errorMessage)")
    .accessibilityLabel("Retry \(repository)")
    .accessibilityHint(errorMessage)
  }

  private var itemCountAccessibilityLabel: String {
    itemCount == 1 ? "1 review" : "\(itemCount) reviews"
  }

  private var countSeparator: some View {
    Text(verbatim: "·")
      .scaledFont(.caption.weight(.semibold))
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      .accessibilityHidden(true)
  }

  private var itemCountText: some View {
    Text(verbatim: "\(itemCount)")
      .monospacedDigit()
      .scaledFont(.caption.weight(.semibold))
      .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      .lineLimit(1)
      .help("\(itemCount) pull requests")
      .accessibilityLabel(itemCountAccessibilityLabel)
  }
}

@MainActor
struct DashboardReviewsSectionHeaderChrome<Content: View>: View {
  let isPinnedFamily: Bool
  let content: Content
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast

  init(
    isPinnedFamily: Bool = false,
    @ViewBuilder content: () -> Content
  ) {
    self.isPinnedFamily = isPinnedFamily
    self.content = content()
  }

  var body: some View {
    content
      .padding(.horizontal, HarnessMonitorTheme.spacingMD)
      .padding(.vertical, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
      .listRowInsets(.all, 0)
      .listRowBackground(Color.clear)
      .background {
        DashboardReviewsSectionHeaderHostBackgroundProbe(
          backgroundColor: sectionBackgroundColor,
          dividerColor: NSColor.separatorColor.withAlphaComponent(dividerOpacity)
        )
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
      }
  }

  private var dividerOpacity: Double {
    colorSchemeContrast == .increased ? 0.55 : 0.35
  }

  private var sectionBackgroundColor: NSColor {
    NSColor(
      srgbRed: 218.0 / 255.0,
      green: 165.0 / 255.0,
      blue: 32.0 / 255.0,
      alpha: 1.0
    )
  }
}

private struct DashboardReviewsSectionHeaderHostBackgroundProbe: NSViewRepresentable {
  let backgroundColor: NSColor
  let dividerColor: NSColor

  func makeNSView(context: Context) -> DashboardReviewsSectionHeaderHostBackgroundProbeView {
    DashboardReviewsSectionHeaderHostBackgroundProbeView(
      backgroundColor: backgroundColor,
      dividerColor: dividerColor
    )
  }

  func updateNSView(
    _ nsView: DashboardReviewsSectionHeaderHostBackgroundProbeView,
    context: Context
  ) {
    nsView.backgroundColor = backgroundColor
    nsView.dividerColor = dividerColor
    nsView.scheduleApply()
  }

  static func dismantleNSView(
    _ nsView: DashboardReviewsSectionHeaderHostBackgroundProbeView,
    coordinator: ()
  ) {
    nsView.detach()
  }
}

private final class DashboardReviewsSectionHeaderHostBackgroundProbeView: NSView {
  var backgroundColor: NSColor {
    didSet { scheduleApply() }
  }

  var dividerColor: NSColor {
    didSet { scheduleApply() }
  }

  private let backgroundLayerName = "harness.reviews.section-header.background.\(UUID().uuidString)"
  private let dividerLayerName = "harness.reviews.section-header.divider.\(UUID().uuidString)"
  private let appliedRowViews = NSHashTable<NSTableRowView>.weakObjects()
  private var isApplyScheduled = false

  init(backgroundColor: NSColor, dividerColor: NSColor) {
    self.backgroundColor = backgroundColor
    self.dividerColor = dividerColor
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    scheduleApply()
  }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    scheduleApply()
  }

  func detach() {
    for rowView in appliedRowViews.allObjects {
      removeInjectedChrome(from: rowView)
    }
    appliedRowViews.removeAllObjects()
  }

  func scheduleApply() {
    guard !isApplyScheduled else { return }
    isApplyScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.isApplyScheduled = false
      self.applyChrome()
    }
  }

  private func applyChrome() {
    guard
      window != nil,
      let rowView = enclosingTableRowView()
    else { return }

    var targetRowViews = [rowView]
    let rowIndex = enclosingTableView(from: rowView)?.row(for: rowView) ?? -1
    if
      let tableView = enclosingTableView(from: rowView),
      rowIndex >= 0,
      let tableRowView = tableView.rowView(atRow: rowIndex, makeIfNecessary: false),
      tableRowView !== rowView
    {
      targetRowViews.append(tableRowView)
    }

    for previousRowView in appliedRowViews.allObjects
    where !targetRowViews.contains(where: { $0 === previousRowView }) {
      removeInjectedChrome(from: previousRowView)
      appliedRowViews.remove(previousRowView)
    }

    for targetRowView in targetRowViews {
      applyChrome(to: targetRowView)
      appliedRowViews.add(targetRowView)
    }
  }

  private func applyChrome(to rowView: NSTableRowView) {
    rowView.backgroundColor = backgroundColor
    rowView.needsDisplay = true
    rowView.wantsLayer = true

    guard let rowLayer = rowView.layer else { return }

    CATransaction.begin()
    CATransaction.setDisableActions(true)

    let backgroundLayer = ensureLayer(named: backgroundLayerName, on: rowLayer)
    backgroundLayer.backgroundColor = backgroundColor.cgColor
    backgroundLayer.frame = rowView.bounds
    backgroundLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

    let dividerLayer = ensureLayer(named: dividerLayerName, on: rowLayer)
    dividerLayer.backgroundColor = dividerColor.cgColor
    dividerLayer.frame = CGRect(x: 0, y: 0, width: rowView.bounds.width, height: 1)
    dividerLayer.autoresizingMask = [.layerWidthSizable, .layerMinYMargin]

    CATransaction.commit()
  }

  private func ensureLayer(named name: String, on container: CALayer) -> CALayer {
    if let existing = container.sublayers?.first(where: { $0.name == name }) {
      return existing
    }

    let layer = CALayer()
    layer.name = name
    container.insertSublayer(layer, at: 0)
    return layer
  }

  private func removeInjectedChrome(from rowView: NSTableRowView) {
    rowView.layer?.sublayers?
      .filter { layer in
        layer.name == backgroundLayerName || layer.name == dividerLayerName
      }
      .forEach { $0.removeFromSuperlayer() }
    rowView.backgroundColor = .clear
    rowView.needsDisplay = true
  }

  private func enclosingTableRowView() -> NSTableRowView? {
    var view = superview
    var depth = 0
    while let current = view, depth < 10 {
      if let rowView = current as? NSTableRowView {
        return rowView
      }
      view = current.superview
      depth += 1
    }
    return nil
  }

  private func enclosingTableView(from rowView: NSTableRowView) -> NSTableView? {
    var view: NSView? = rowView
    var depth = 0
    while let current = view, depth < 10 {
      if let tableView = current as? NSTableView {
        return tableView
      }
      view = current.superview
      depth += 1
    }
    return nil
  }
}

private func dashboardReviewsRepositorySectionHeaderRelativeSyncDescription(
  date: Date,
  referenceDate: Date = .now
) -> (display: String, accessibility: String) {
  let elapsedSeconds = max(0, Int(referenceDate.timeIntervalSince(date)))
  switch elapsedSeconds {
  case ..<60:
    return ("<1 min ago", "less than 1 minute ago")
  case ..<3_600:
    let minutes = max(1, elapsedSeconds / 60)
    return (
      "\(minutes) min ago",
      minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago"
    )
  case ..<86_400:
    let hours = elapsedSeconds / 3_600
    return (
      "\(hours) hr ago",
      hours == 1 ? "1 hour ago" : "\(hours) hours ago"
    )
  case ..<604_800:
    let days = elapsedSeconds / 86_400
    return (
      "\(days) day\(days == 1 ? "" : "s") ago",
      days == 1 ? "1 day ago" : "\(days) days ago"
    )
  case ..<2_629_800:
    let weeks = elapsedSeconds / 604_800
    return (
      "\(weeks) wk ago",
      weeks == 1 ? "1 week ago" : "\(weeks) weeks ago"
    )
  case ..<31_557_600:
    let months = elapsedSeconds / 2_629_800
    return (
      "\(months) mo ago",
      months == 1 ? "1 month ago" : "\(months) months ago"
    )
  default:
    let years = elapsedSeconds / 31_557_600
    return (
      "\(years) yr ago",
      years == 1 ? "1 year ago" : "\(years) years ago"
    )
  }
}

@MainActor
private struct DashboardReviewsRepositoryHeaderPill: View {
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
