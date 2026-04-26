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
      Text("Signals")
        .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      if signals.isEmpty && !isExtensionsLoading {
        SessionCockpitEmptyStateRow(section: .signals)
      } else {
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
        store.presentedSheet = .signalDetail(signalID: signal.signal.signalId)
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
          store.presentedSheet = .signalDetail(signalID: signal.signal.signalId)
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

  @State private var displayScale: CGFloat = Self.hiddenScale
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
        .fill(.clear)
        .harnessPanelGlass()
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
  @ScaledMetric(relativeTo: .title3)
  private var actionIconSize: CGFloat = 28

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
        .frame(width: actionIconSize, height: actionIconSize)
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
  @ScaledMetric(relativeTo: .title3)
  private var actionIconSize: CGFloat = 28

  var body: some View {
    Button {
      Task { await store.resendSignal(signal) }
    } label: {
      Image(systemName: "arrow.clockwise")
        .symbolRenderingMode(useWhiteTint ? .monochrome : .hierarchical)
        .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
        .foregroundStyle(useWhiteTint ? Color.white : HarnessMonitorTheme.accent)
        .opacity(isHovering ? 1 : (useWhiteTint ? 0.9 : 0.7))
        .frame(width: actionIconSize, height: actionIconSize)
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
