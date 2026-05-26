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
  let presentationMode: DashboardReviewsSectionHeaderPresentationMode

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
    DashboardReviewsSectionHeaderChrome(
      isPinnedFamily: isPinned,
      presentationMode: presentationMode
    ) {
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
      Label("Error", systemImage: "exclamationmark.triangle")
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.caution)
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
        .help(message)
        .accessibilityLabel("Last sync failed: \(message)")
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
      Text("Never synced")
        .scaledFont(.caption.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .lineLimit(1)
        .accessibilityLabel("Never synced")
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

enum DashboardReviewsSectionHeaderPresentationMode: Sendable {
  case sectionRow
  case stickyOverlay
}

private enum DashboardReviewsSectionHeaderAppKitIdentifiers {
  static let tableView = NSUserInterfaceItemIdentifier("harness.reviews.list.table")
  static let stickyBackdrop = NSUserInterfaceItemIdentifier("harness.reviews.list.sticky-backdrop")
}

private struct DashboardReviewsSectionHeaderChromePalette {
  let baseBackgroundColor: NSColor
  let tintColor: NSColor
  let dividerColor: NSColor
}

@MainActor
struct DashboardReviewsSectionHeaderChrome<Content: View>: View {
  let isPinnedFamily: Bool
  let presentationMode: DashboardReviewsSectionHeaderPresentationMode
  let content: Content
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  init(
    isPinnedFamily: Bool = false,
    presentationMode: DashboardReviewsSectionHeaderPresentationMode = .sectionRow,
    @ViewBuilder content: () -> Content
  ) {
    self.isPinnedFamily = isPinnedFamily
    self.presentationMode = presentationMode
    self.content = content()
  }

  var body: some View {
    switch presentationMode {
    case .sectionRow:
      sectionRowChrome
    case .stickyOverlay:
      stickyOverlayChrome
    }
  }

  private var paddedContent: some View {
    content
      .padding(.horizontal, DashboardReviewsVisualMetrics.reviewRowHorizontalPadding)
      .padding(.vertical, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var sectionRowChrome: some View {
    paddedContent
      .listRowInsets(.all, 0)
      .listRowBackground(Color.clear)
      .background {
        DashboardReviewsSectionHeaderRowBackgroundProbe(
          baseBackgroundColor: palette.baseBackgroundColor,
          tintColor: palette.tintColor,
          dividerColor: palette.dividerColor
        )
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
      }
  }

  private var stickyOverlayChrome: some View {
    paddedContent
      .background {
        stickyOverlayBackground
      }
      .overlay(alignment: .bottom) {
        Rectangle()
          .fill(Color(nsColor: palette.dividerColor))
          .frame(height: 1)
      }
  }

  @ViewBuilder
  private var stickyOverlayBackground: some View {
    if reduceTransparency {
      Color(nsColor: palette.baseBackgroundColor)
        .overlay {
          Color(nsColor: palette.tintColor)
        }
    } else {
      DashboardReviewsStickyHeaderBackdropProbe(tintColor: palette.tintColor)
    }
  }

  private var palette: DashboardReviewsSectionHeaderChromePalette {
    DashboardReviewsSectionHeaderChromePalette(
      baseBackgroundColor: NSColor.windowBackgroundColor.withAlphaComponent(
        reduceTransparency ? 1.0 : (colorSchemeContrast == .increased ? 0.94 : 0.82)
      ),
      tintColor: isPinnedFamily
        ? NSColor(HarnessMonitorTheme.accent)
          .withAlphaComponent(colorSchemeContrast == .increased ? 0.14 : 0.10)
        : NSColor(HarnessMonitorTheme.ink)
          .withAlphaComponent(colorSchemeContrast == .increased ? 0.055 : 0.035),
      dividerColor: NSColor.separatorColor
    )
  }
}

private final class DashboardReviewsStickyHeaderMaterialEffectView: NSVisualEffectView {
  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }
}

private struct DashboardReviewsStickyHeaderBackdropProbe: NSViewRepresentable {
  let tintColor: NSColor

  func makeNSView(context: Context) -> DashboardReviewsStickyHeaderBackdropProbeView {
    DashboardReviewsStickyHeaderBackdropProbeView(tintColor: tintColor)
  }

  func updateNSView(
    _ nsView: DashboardReviewsStickyHeaderBackdropProbeView,
    context: Context
  ) {
    nsView.tintColor = tintColor
    nsView.scheduleApply()
  }

  static func dismantleNSView(
    _ nsView: DashboardReviewsStickyHeaderBackdropProbeView,
    coordinator: ()
  ) {
    nsView.detach()
  }
}

@MainActor
private final class DashboardReviewsStickyHeaderBackdropProbeView: NSView {
  var tintColor: NSColor {
    didSet { scheduleApply() }
  }

  private weak var installedScrollView: NSScrollView?
  private weak var backdropView: DashboardReviewsStickyHeaderBackdropView?
  private var isApplyScheduled = false

  init(tintColor: NSColor) {
    self.tintColor = tintColor
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  override func layout() {
    super.layout()
    scheduleApply()
  }

  override func viewWillMove(toSuperview newSuperview: NSView?) {
    if newSuperview == nil {
      detach()
    }
    super.viewWillMove(toSuperview: newSuperview)
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
    backdropView?.removeFromSuperview()
    backdropView = nil
    installedScrollView = nil
  }

  func scheduleApply() {
    guard !isApplyScheduled else { return }
    isApplyScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.isApplyScheduled = false
      self.applyBackdrop()
    }
  }

  private func applyBackdrop() {
    guard
      let window,
      let scrollView = dashboardReviewsStickyHeaderScrollView(in: window)
    else {
      detach()
      return
    }

    let backdrop = ensureBackdrop(on: scrollView)
    backdrop.tintColor = tintColor

    let frameInWindow = convert(bounds, to: nil)
    var frame = scrollView.convert(frameInWindow, from: nil)
    frame.origin.x = scrollView.contentView.frame.minX
    frame.size.width = scrollView.contentView.bounds.width
    backdrop.frame = frame.integral
  }

  private func ensureBackdrop(on scrollView: NSScrollView) -> DashboardReviewsStickyHeaderBackdropView {
    if installedScrollView !== scrollView {
      detach()
      installedScrollView = scrollView
    }

    if let backdropView {
      if backdropView.superview !== scrollView {
        backdropView.removeFromSuperview()
        scrollView.addSubview(backdropView, positioned: .above, relativeTo: scrollView.contentView)
      }
      return backdropView
    }

    let backdrop = DashboardReviewsStickyHeaderBackdropView(tintColor: tintColor)
    backdrop.identifier = DashboardReviewsSectionHeaderAppKitIdentifiers.stickyBackdrop
    scrollView.addSubview(backdrop, positioned: .above, relativeTo: scrollView.contentView)
    backdropView = backdrop
    return backdrop
  }
}

@MainActor
private final class DashboardReviewsStickyHeaderBackdropView: NSView {
  var tintColor: NSColor {
    didSet {
      tintView.layer?.backgroundColor = tintColor.cgColor
    }
  }

  private let effectView = DashboardReviewsStickyHeaderMaterialEffectView()
  private let tintView = NSView()

  init(tintColor: NSColor) {
    self.tintColor = tintColor
    super.init(frame: .zero)
    wantsLayer = true
    layer?.masksToBounds = true

    effectView.material = .headerView
    effectView.blendingMode = .withinWindow
    effectView.state = .active
    effectView.isEmphasized = false
    addSubview(effectView)

    tintView.wantsLayer = true
    tintView.layer?.backgroundColor = tintColor.cgColor
    addSubview(tintView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  override func layout() {
    super.layout()
    effectView.frame = bounds
    tintView.frame = bounds
  }
}

@MainActor
private func dashboardReviewsStickyHeaderScrollView(in window: NSWindow) -> NSScrollView? {
  guard let contentView = window.contentView else { return nil }
  return dashboardReviewsStickyHeaderFindTableView(in: contentView)?.enclosingScrollView
}

@MainActor
private func dashboardReviewsStickyHeaderFindTableView(in root: NSView) -> NSTableView? {
  if let tableView = root as? NSTableView,
    tableView.identifier == DashboardReviewsSectionHeaderAppKitIdentifiers.tableView
  {
    return tableView
  }
  for subview in root.subviews {
    if let tableView = dashboardReviewsStickyHeaderFindTableView(in: subview) {
      return tableView
    }
  }
  return nil
}

private struct DashboardReviewsSectionHeaderRowBackgroundProbe: NSViewRepresentable {
  let baseBackgroundColor: NSColor
  let tintColor: NSColor
  let dividerColor: NSColor

  func makeNSView(context: Context) -> DashboardReviewsSectionHeaderRowBackgroundProbeView {
    DashboardReviewsSectionHeaderRowBackgroundProbeView(
      baseBackgroundColor: baseBackgroundColor,
      tintColor: tintColor,
      dividerColor: dividerColor
    )
  }

  func updateNSView(
    _ nsView: DashboardReviewsSectionHeaderRowBackgroundProbeView,
    context: Context
  ) {
    nsView.baseBackgroundColor = baseBackgroundColor
    nsView.tintColor = tintColor
    nsView.dividerColor = dividerColor
    nsView.scheduleApply()
  }

  static func dismantleNSView(
    _ nsView: DashboardReviewsSectionHeaderRowBackgroundProbeView,
    coordinator: ()
  ) {
    nsView.detach()
  }
}

private final class DashboardReviewsSectionHeaderRowBackgroundProbeView: NSView {
  var baseBackgroundColor: NSColor {
    didSet { scheduleApply() }
  }

  var tintColor: NSColor {
    didSet { scheduleApply() }
  }

  var dividerColor: NSColor {
    didSet { scheduleApply() }
  }

  private weak var appliedRowView: NSTableRowView?
  private var isApplyScheduled = false

  private let backgroundLayerName = "harness.reviews.section-header.background"
  private let tintLayerName = "harness.reviews.section-header.tint"
  private let dividerLayerName = "harness.reviews.section-header.divider"

  init(baseBackgroundColor: NSColor, tintColor: NSColor, dividerColor: NSColor) {
    self.baseBackgroundColor = baseBackgroundColor
    self.tintColor = tintColor
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

  override func viewWillMove(toSuperview newSuperview: NSView?) {
    if newSuperview == nil {
      detach()
    }
    super.viewWillMove(toSuperview: newSuperview)
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
    guard let appliedRowView else { return }
    removeInjectedChrome(from: appliedRowView)
    self.appliedRowView = nil
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
    else {
      detach()
      return
    }

    if appliedRowView !== rowView {
      detach()
      appliedRowView = rowView
    }

    rowView.backgroundColor = .clear
    rowView.needsDisplay = true
    rowView.wantsLayer = true

    guard let rowLayer = rowView.layer else { return }

    CATransaction.begin()
    CATransaction.setDisableActions(true)

    let backgroundLayer = ensureLayer(named: backgroundLayerName, on: rowLayer, at: 0)
    backgroundLayer.backgroundColor = baseBackgroundColor.cgColor
    backgroundLayer.frame = rowView.bounds
    backgroundLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

    let tintLayer = ensureLayer(named: tintLayerName, on: rowLayer, at: 1)
    tintLayer.backgroundColor = tintColor.cgColor
    tintLayer.frame = rowView.bounds
    tintLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

    let dividerLayer = ensureLayer(named: dividerLayerName, on: rowLayer, at: 2)
    dividerLayer.backgroundColor = dividerColor.cgColor
    dividerLayer.frame = CGRect(
      x: 0,
      y: max(rowView.bounds.height - 1, 0),
      width: rowView.bounds.width,
      height: 1
    )
    dividerLayer.autoresizingMask = [.layerWidthSizable, .layerMinYMargin]

    CATransaction.commit()
  }

  private func ensureLayer(named name: String, on container: CALayer, at index: UInt32) -> CALayer {
    if let existing = container.sublayers?.first(where: { $0.name == name }) {
      if let currentIndex = container.sublayers?.firstIndex(where: { $0 === existing }),
        currentIndex != Int(index)
      {
        existing.removeFromSuperlayer()
        container.insertSublayer(existing, at: index)
      }
      return existing
    }

    let layer = CALayer()
    layer.name = name
    container.insertSublayer(layer, at: index)
    return layer
  }

  private func removeInjectedChrome(from rowView: NSTableRowView) {
    let injectedLayers =
      rowView.layer?.sublayers?.filter { layer in
        layer.name == backgroundLayerName
          || layer.name == tintLayerName
          || layer.name == dividerLayerName
      } ?? []
    for injectedLayer in injectedLayers {
      injectedLayer.removeFromSuperlayer()
    }
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
}

struct DashboardReviewsListTableConfigurationProbe: NSViewRepresentable {
  func makeNSView(context: Context) -> DashboardReviewsListTableConfigurationProbeView {
    DashboardReviewsListTableConfigurationProbeView()
  }

  func updateNSView(_ nsView: DashboardReviewsListTableConfigurationProbeView, context: Context) {
    nsView.scheduleApply()
  }

  static func dismantleNSView(
    _ nsView: DashboardReviewsListTableConfigurationProbeView,
    coordinator: ()
  ) {
    nsView.detach()
  }
}

final class DashboardReviewsListTableConfigurationProbeView: NSView {
  private weak var configuredTableView: NSTableView?
  private var originalFloatsGroupRows: Bool?
  private var originalTableViewIdentifier: NSUserInterfaceItemIdentifier?
  private var isApplyScheduled = false

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
    scheduleApply()
  }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    scheduleApply()
  }

  func detach() {
    if let configuredTableView {
      if let originalFloatsGroupRows {
        configuredTableView.floatsGroupRows = originalFloatsGroupRows
      }
      configuredTableView.identifier = originalTableViewIdentifier
    }
    configuredTableView = nil
    originalFloatsGroupRows = nil
    originalTableViewIdentifier = nil
  }

  func scheduleApply() {
    guard !isApplyScheduled else { return }
    isApplyScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.isApplyScheduled = false
      self.applyConfiguration()
    }
  }

  private func applyConfiguration() {
    guard
      window != nil,
      let tableView = enclosingTableView()
    else {
      detach()
      return
    }

    if configuredTableView !== tableView {
      detach()
      configuredTableView = tableView
      originalFloatsGroupRows = tableView.floatsGroupRows
      originalTableViewIdentifier = tableView.identifier
    }

    tableView.floatsGroupRows = false
    tableView.identifier = DashboardReviewsSectionHeaderAppKitIdentifiers.tableView
  }

  private func enclosingTableView() -> NSTableView? {
    var view = superview
    var depth = 0
    while let current = view, depth < 12 {
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
