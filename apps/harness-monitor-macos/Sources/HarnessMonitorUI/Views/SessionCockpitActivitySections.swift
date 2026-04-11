import HarnessMonitorKit
import SwiftUI

struct SessionCockpitSignalsSection: View {
  let store: HarnessMonitorStore
  let signals: [SessionSignalRecord]
  let isExtensionsLoading: Bool
  let isSessionReadOnly: Bool
  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      HStack(alignment: .center, spacing: HarnessMonitorTheme.sectionSpacing) {
        Text("Signals")
          .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
          .accessibilityAddTraits(.isHeader)
          .opacity(signals.isEmpty && !isExtensionsLoading ? 0.55 : 1)
        Spacer(minLength: 0)
        if signals.isEmpty && !isExtensionsLoading {
          Text("No signals yet")
            .scaledFont(.system(.body, design: .rounded))
            .foregroundStyle(.tertiary)
            .opacity(0.75)
        }
      }
      LazyVStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
        ForEach(signals) { signal in
          SessionCockpitSignalCard(
            store: store,
            signal: signal,
            isSessionReadOnly: isSessionReadOnly,
            dateTimeConfiguration: dateTimeConfiguration
          )
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct SessionCockpitSignalCard: View {
  let store: HarnessMonitorStore
  let signal: SessionSignalRecord
  let isSessionReadOnly: Bool
  let dateTimeConfiguration: HarnessMonitorDateTimeConfiguration

  @State private var isHovered = false
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  private var effectiveStatus: SessionSignalStatus {
    signal.effectiveStatus
  }

  private var canCancel: Bool {
    !isSessionReadOnly && effectiveStatus == .pending
  }

  private var canResend: Bool {
    !isSessionReadOnly && effectiveStatus == .expired
  }

  private var showsActions: Bool {
    canCancel || canResend
  }

  private var hoverAnimation: Animation? {
    reduceMotion ? nil : .easeOut(duration: 0.15)
  }

  private var firstMessageLine: String {
    let message = signal.signal.payload.message
    if let newlineIndex = message.firstIndex(where: \.isNewline) {
      return String(message[..<newlineIndex])
    }
    return message
  }

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Button {
        store.inspect(signalID: signal.signal.signalId)
      } label: {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
          HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.sectionSpacing) {
            Text(signal.signal.command)
              .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
              .frame(maxWidth: .infinity, alignment: .leading)
            Text(effectiveStatus.title)
              .scaledFont(.caption.bold())
              .foregroundStyle(signalStatusColor(for: effectiveStatus))
          }
          HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.sectionSpacing) {
            HarnessMonitorMarkdownText(
              firstMessageLine,
              font: .subheadline,
              rendering: .plainPreview,
              lineLimit: 1
            )
            Text(formatTimestamp(signal.signal.createdAt, configuration: dateTimeConfiguration))
              .scaledFont(.caption.monospaced())
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              .fixedSize(horizontal: true, vertical: false)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(HarnessMonitorTheme.cardPadding)
      }
      .harnessInteractiveCardButtonStyle(extraHoverHint: isHovered && showsActions)
      .accessibilityIdentifier(
        HarnessMonitorAccessibility.sessionSignalCard(signal.signal.signalId)
      )
      .contextMenu {
        Button {
          store.inspect(signalID: signal.signal.signalId)
        } label: {
          Label("Inspect", systemImage: "info.circle")
        }
        if canCancel {
          Button(role: .destructive) {
            Task {
              await store.cancelSignal(
                signalID: signal.signal.signalId,
                agentID: signal.agentId
              )
            }
          } label: {
            Label("Cancel Signal", systemImage: "xmark.circle")
          }
        }
        if canResend {
          Button {
            Task { await store.resendSignal(signal) }
          } label: {
            Label("Resend Signal", systemImage: "arrow.clockwise")
          }
        }
        Divider()
        Button {
          HarnessMonitorClipboard.copy(signal.signal.signalId)
        } label: {
          Label("Copy Signal ID", systemImage: "doc.on.doc")
        }
      }

      // Keep hidden material/mask overlays out of the render tree; Instruments
      // still counts their work even when the strip is fully transparent.
      if isHovered && showsActions {
        SignalHoverActionStrip(
          store: store,
          signal: signal,
          canCancel: canCancel,
          canResend: canResend,
          reduceMotion: reduceMotion
        )
        .transition(
          reduceMotion
            ? .identity
            : .opacity.combined(
              with: .scale(scale: SignalHoverActionStrip.hiddenScale, anchor: .topTrailing)
            )
        )
      }
    }
    .onHover { hovered in
      withAnimation(hoverAnimation) {
        isHovered = hovered
      }
    }
  }
}

private struct SignalHoverActionStrip: View {
  static let hiddenScale: CGFloat = 0.2
  static let bouncingScale: CGFloat = 1
  // 1.001 forces a @State change when interrupting the bouncy spring mid-flight -
  // withAnimation only re-triggers if the target value differs, so settling to 1.0
  // when the state is already 1.0 would be a no-op and the spring would keep running.
  static let settledScale: CGFloat = 1.001

  let store: HarnessMonitorStore
  let signal: SessionSignalRecord
  let canCancel: Bool
  let canResend: Bool
  let reduceMotion: Bool

  @State private var displayScale: CGFloat = SignalHoverActionStrip.hiddenScale
  @State private var isCancelHovering = false
  @State private var isResendHovering = false

  private var anyIconHovering: Bool {
    isCancelHovering || isResendHovering
  }

  private var soloTintColor: Color? {
    if canCancel && !canResend { return HarnessMonitorTheme.danger }
    if canResend && !canCancel { return HarnessMonitorTheme.accent }
    return nil
  }

  private var overlayColor: Color {
    soloTintColor ?? .black
  }

  private var overlayPeakOpacity: Double {
    soloTintColor == nil ? 0.35 : 0.7
  }

  var body: some View {
    VStack(spacing: HarnessMonitorTheme.itemSpacing) {
      if canCancel {
        SignalCancelActionButton(
          store: store,
          signal: signal,
          useWhiteTint: soloTintColor != nil,
          isHovering: $isCancelHovering
        )
      }
      if canResend {
        SignalResendActionButton(
          store: store,
          signal: signal,
          useWhiteTint: soloTintColor != nil,
          isHovering: $isResendHovering
        )
      }
    }
    .scaleEffect(reduceMotion ? Self.bouncingScale : displayScale, anchor: .center)
    .onAppear {
      guard !reduceMotion else {
        return
      }
      withAnimation(.interpolatingSpring(mass: 1, stiffness: 180, damping: 6)) {
        displayScale = Self.bouncingScale
      }
    }
    .onChange(of: anyIconHovering) { _, newValue in
      guard newValue, !reduceMotion else { return }
      withAnimation(.easeOut(duration: 0.12)) {
        displayScale = Self.settledScale
      }
    }
    .frame(maxHeight: .infinity, alignment: .top)
    .padding(.leading, HarnessMonitorTheme.spacingLG * 6)
    .padding(.trailing, HarnessMonitorTheme.cardPadding)
    .padding(.vertical, HarnessMonitorTheme.cardPadding)
    .background {
      Rectangle()
        .fill(.thinMaterial)
        .overlay {
          LinearGradient(
            colors: [
              overlayColor.opacity(0),
              overlayColor.opacity(overlayPeakOpacity),
            ],
            startPoint: .bottomLeading,
            endPoint: .topTrailing
          )
        }
        .mask {
          LinearGradient(
            stops: [
              .init(color: .clear, location: 0),
              .init(color: .black.opacity(0.5), location: 0.35),
              .init(color: .black, location: 0.6),
            ],
            startPoint: .leading,
            endPoint: .trailing
          )
        }
        .mask {
          LinearGradient(
            stops: [
              .init(color: .black, location: 0),
              .init(color: .black.opacity(0.55), location: 0.55),
              .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
          )
        }
    }
    .clipShape(
      UnevenRoundedRectangle(
        topLeadingRadius: 0,
        bottomLeadingRadius: 0,
        bottomTrailingRadius: HarnessMonitorTheme.cornerRadiusMD,
        topTrailingRadius: HarnessMonitorTheme.cornerRadiusMD,
        style: .continuous
      )
    )
  }
}

private struct SignalActionButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.82 : 1)
      .brightness(configuration.isPressed ? -0.05 : 0)
      .animation(.spring(response: 0.18, dampingFraction: 0.55), value: configuration.isPressed)
  }
}

private struct SignalCancelActionButton: View {
  let store: HarnessMonitorStore
  let signal: SessionSignalRecord
  let useWhiteTint: Bool
  @Binding var isHovering: Bool

  var body: some View {
    Button {
      Task {
        await store.cancelSignal(
          signalID: signal.signal.signalId,
          agentID: signal.agentId
        )
      }
    } label: {
      Image(systemName: "xmark.circle")
        .symbolRenderingMode(useWhiteTint ? .monochrome : .hierarchical)
        .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
        .foregroundStyle(useWhiteTint ? Color.white : HarnessMonitorTheme.danger)
        .opacity(isHovering ? 1 : (useWhiteTint ? 0.9 : 0.7))
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
        .scaleEffect(isHovering ? 1.22 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.65), value: isHovering)
    }
    .buttonStyle(SignalActionButtonStyle())
    .help("Cancel pending signal")
    .accessibilityLabel("Cancel signal")
    .onHover { isHovering = $0 }
  }
}

private struct SignalResendActionButton: View {
  let store: HarnessMonitorStore
  let signal: SessionSignalRecord
  let useWhiteTint: Bool
  @Binding var isHovering: Bool

  var body: some View {
    Button {
      Task { await store.resendSignal(signal) }
    } label: {
      Image(systemName: "arrow.clockwise")
        .symbolRenderingMode(useWhiteTint ? .monochrome : .hierarchical)
        .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
        .foregroundStyle(useWhiteTint ? Color.white : HarnessMonitorTheme.accent)
        .opacity(isHovering ? 1 : (useWhiteTint ? 0.9 : 0.7))
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
        .scaleEffect(isHovering ? 1.22 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.65), value: isHovering)
    }
    .buttonStyle(SignalActionButtonStyle())
    .help("Resend signal")
    .accessibilityLabel("Resend signal")
    .onHover { isHovering = $0 }
  }
}

#Preview("Signals") {
  SessionCockpitSignalsSection(
    store: HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded),
    signals: PreviewFixtures.signals,
    isExtensionsLoading: false,
    isSessionReadOnly: false
  )
  .padding()
  .frame(width: 960)
}

struct SessionCockpitTimelineSection: View {
  let sessionID: String
  let timeline: [TimelineEntry]
  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @State private var currentPage = 0
  @State private var pageSize = SessionTimelinePageSize.defaultSize

  private var currentEntries: [TimelineEntry] {
    SessionTimelinePagination.currentEntries(
      in: timeline,
      currentPage: resolvedCurrentPage,
      pageSize: pageSize.rawValue
    )
  }

  private var pageCount: Int {
    SessionTimelinePagination.pageCount(for: timeline.count, pageSize: pageSize.rawValue)
  }

  private var resolvedCurrentPage: Int {
    SessionTimelinePagination.clampedPage(
      currentPage,
      itemCount: timeline.count,
      pageSize: pageSize.rawValue
    )
  }

  private var pageStatusText: String {
    "Page \(resolvedCurrentPage + 1) of \(pageCount)"
  }

  private var pageRangeText: String {
    let lowerBound = (resolvedCurrentPage * pageSize.rawValue) + 1
    let upperBound = min(lowerBound + currentEntries.count - 1, timeline.count)
    return "Showing \(lowerBound)-\(upperBound) of \(timeline.count)"
  }

  private var showsPagination: Bool {
    pageCount > 1
  }

  private var pageChangeAnimation: Animation? {
    reduceMotion ? nil : .snappy(duration: 0.22, extraBounce: 0)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      Text("Timeline")
        .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      if timeline.isEmpty {
        ContentUnavailableView {
          Label("No activity yet", systemImage: "clock")
        } description: {
          Text("Timeline entries appear as agents work on tasks.")
        }
        .frame(maxWidth: .infinity)
      } else {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingLG) {
          SessionTimelinePageSummary(
            rangeText: pageRangeText,
            pageSize: $pageSize
          )

          LazyVStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
            ForEach(currentEntries) { entry in
              SessionCockpitTimelineEntryRow(
                entry: entry,
                dateTimeConfiguration: dateTimeConfiguration
              )
            }
          }
          .id("\(pageSize.rawValue)-\(resolvedCurrentPage)")
          .frame(maxWidth: .infinity, alignment: .leading)

          if showsPagination {
            SessionTimelinePaginationFooter(
              currentPage: resolvedCurrentPage,
              pageCount: pageCount,
              pageStatusText: pageStatusText,
              visiblePages: SessionTimelinePagination.visiblePages(
                currentPage: resolvedCurrentPage,
                pageCount: pageCount
              ),
              goToPreviousPage: { changePage(to: currentPage - 1) },
              goToNextPage: { changePage(to: currentPage + 1) },
              goToPage: changePage(to:)
            )
            .accessibilityIdentifier(HarnessMonitorAccessibility.sessionTimelinePagination)
          }
        }
        .padding(HarnessMonitorTheme.spacingLG)
        .background {
          RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusLG, style: .continuous)
            .fill(.primary.opacity(0.035))
            .overlay {
              RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusLG, style: .continuous)
                .stroke(HarnessMonitorTheme.controlBorder.opacity(0.55), lineWidth: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: sessionID) { _, _ in
          currentPage = 0
        }
        .onChange(of: pageSize) { oldPageSize, newPageSize in
          setCurrentPage(
            SessionTimelinePagination.rebasedPage(
              currentPage,
              itemCount: timeline.count,
              oldPageSize: oldPageSize.rawValue,
              newPageSize: newPageSize.rawValue
            )
          )
        }
        .onChange(of: timeline) { _, newTimeline in
          currentPage = SessionTimelinePagination.clampedPage(
            currentPage,
            itemCount: newTimeline.count,
            pageSize: pageSize.rawValue
          )
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func changePage(to page: Int) {
    let clampedPage = SessionTimelinePagination.clampedPage(
      page,
      itemCount: timeline.count,
      pageSize: pageSize.rawValue
    )
    guard clampedPage != currentPage else {
      return
    }

    setCurrentPage(clampedPage)
  }

  private func setCurrentPage(_ page: Int) {
    if let pageChangeAnimation {
      withAnimation(pageChangeAnimation) {
        currentPage = page
      }
    } else {
      currentPage = page
    }
  }
}

private struct SessionTimelineEntryMarker: View {
  @ScaledMetric(relativeTo: .body)
  private var markerHeight = 18.0
  @ScaledMetric(relativeTo: .body)
  private var markerWidth = 6.0

  var body: some View {
    RoundedRectangle(cornerRadius: markerWidth / 2, style: .continuous)
      .fill(HarnessMonitorTheme.accent.opacity(0.45))
      .frame(width: markerWidth, height: markerHeight)
      .accessibilityHidden(true)
  }
}

private struct SessionCockpitTimelineEntryRow: View {
  let entry: TimelineEntry
  let dateTimeConfiguration: HarnessMonitorDateTimeConfiguration

  var body: some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.sectionSpacing) {
      SessionTimelineEntryMarker()
      Text(formatTimelineTimestamp(entry.recordedAt, configuration: dateTimeConfiguration))
        .scaledFont(.caption.monospaced())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
      Text(entry.summary)
        .scaledFont(.system(.body, design: .rounded, weight: .semibold))
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
      Text(entry.kind)
        .scaledFont(.caption.monospaced())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(HarnessMonitorTheme.cardPadding)
    .background {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
        .fill(.primary.opacity(0.04))
    }
    .contextMenu {
      Button {
        HarnessMonitorClipboard.copy(entry.summary)
      } label: {
        Label("Copy Summary", systemImage: "doc.on.doc")
      }
      if let taskID = entry.taskId {
        Button {
          HarnessMonitorClipboard.copy(taskID)
        } label: {
          Label("Copy Task ID", systemImage: "doc.on.doc")
        }
      }
    }
  }
}

#Preview("Timeline Pagination") {
  SessionCockpitTimelineSection(
    sessionID: PreviewFixtures.summary.sessionId,
    timeline: PreviewFixtures.pagedTimeline
  )
  .padding()
  .frame(width: 960)
}

#Preview("Timeline") {
  SessionCockpitTimelineSection(
    sessionID: PreviewFixtures.summary.sessionId,
    timeline: PreviewFixtures.timeline
  )
  .padding()
  .frame(width: 960)
}
