import HarnessMonitorKit
import SwiftUI

struct SessionCockpitHeaderCard: View {
  let store: HarnessMonitorStore
  let detail: SessionDetail
  let isSessionReadOnly: Bool
  let observeSelectedSession: () -> Void
  let requestEndSessionConfirmation: () -> Void
  let inspectObserver: () -> Void
  let createTask: () -> Void
  @Environment(\.harnessDateTimeConfiguration)
  private var dateTimeConfiguration

  private struct SupplementalSummaryVisibility: Equatable {
    let hasObserver: Bool
    let hasPendingLeaderTransfer: Bool
  }

  private var supplementalSummaryVisibility: SupplementalSummaryVisibility {
    SupplementalSummaryVisibility(
      hasObserver: detail.observer != nil,
      hasPendingLeaderTransfer: detail.session.pendingLeaderTransfer != nil
    )
  }

  private var areSessionActionsAvailable: Bool {
    store.areSelectedSessionActionsAvailable
  }

  private var unavailableActionHelp: String {
    store.selectedSessionActionUnavailableMessage ?? ""
  }

  private var newTaskHelp: String {
    if unavailableActionHelp.isEmpty {
      "Create a new task in this session (⌘T)"
    } else {
      unavailableActionHelp
    }
  }

  private var awaitingLeaderMessage: String? {
    guard detail.session.status == .awaitingLeader else {
      return nil
    }
    return """
      This session is waiting for its first leader. You can still seed tasks,
      observe progress, or end it from the control plane.
      """
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
          Text(detail.session.displayTitle)
            .scaledFont(.system(.largeTitle, design: .rounded, weight: .black))
            .italic(detail.session.title.isEmpty)
            .foregroundStyle(
              detail.session.title.isEmpty
                ? HarnessMonitorTheme.tertiaryInk
                : HarnessMonitorTheme.ink
            )
            .lineLimit(2)
          Text(sessionHeaderMetadata(detail.session))
            .scaledFont(.system(.subheadline, design: .rounded, weight: .medium))
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          Text(
            sessionLeaderAndActivityLine(
              detail.session,
              configuration: dateTimeConfiguration
            )
          )
          .scaledFont(.system(.footnote, design: .rounded, weight: .medium))
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .accessibilityIdentifier(HarnessMonitorAccessibility.sessionHeaderLeaderActivity)
          let shouldShowContext =
            !detail.session.context.isEmpty
            && detail.session.context != detail.session.displayTitle
          if shouldShowContext {
            Text(detail.session.context)
              .scaledFont(.system(.body, design: .rounded, weight: .medium))
              .foregroundStyle(HarnessMonitorTheme.secondaryInk)
              .lineLimit(3)
          }
        }
        Spacer()
        HarnessMonitorGlassControlGroup(spacing: HarnessMonitorTheme.itemSpacing) {
          HStack(spacing: HarnessMonitorTheme.itemSpacing) {
            newTaskButton
            observeButton
            if detail.agents.count > 1 {
              transferLeadershipButton
            }
            endSessionButton
          }
        }
      }

      if let observer = detail.observer {
        observerSummary(observer)
          .transition(.opacity)
      }

      if let awaitingLeaderMessage {
        awaitingLeaderSummary(awaitingLeaderMessage)
          .transition(.opacity)
      }

      if let pendingTransfer = detail.session.pendingLeaderTransfer {
        pendingTransferSummary(pendingTransfer)
          .transition(.opacity)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .animation(.spring(duration: 0.3), value: supplementalSummaryVisibility)
    .accessibilityTestProbe(HarnessMonitorAccessibility.sessionHeaderCard)
    .accessibilityFrameMarker(HarnessMonitorAccessibility.sessionHeaderCardFrame)
  }

  private var newTaskButton: some View {
    Button("New Task") {
      createTask()
    }
    .harnessActionButtonStyle(variant: .bordered)
    .help(newTaskHelp)
    .accessibilityIdentifier(HarnessMonitorAccessibility.createTaskOpenButton)
    .disabled(!areSessionActionsAvailable || isSessionReadOnly)
  }

  private var observeButton: some View {
    HarnessInlineActionButton(
      title: "Observe",
      actionID: .observeSession(sessionID: detail.session.sessionId),
      store: store,
      variant: .prominent,
      tint: nil,
      isExternallyDisabled: !areSessionActionsAvailable,
      accessibilityIdentifier: HarnessMonitorAccessibility.observeSessionButton,
      help: unavailableActionHelp,
      action: { observeSelectedSession() }
    )
  }

  private var transferLeadershipButton: some View {
    Button("Transfer Leadership") {
      store.presentedSheet = .leaderTransfer(sessionID: detail.session.sessionId)
    }
    .harnessActionButtonStyle(variant: .bordered)
    .help("Open the leadership transfer sheet")
    .accessibilityIdentifier(HarnessMonitorAccessibility.leaderTransferOpenButton)
    .disabled(!store.areSelectedLeaderActionsAvailable)
  }

  private var endSessionButton: some View {
    HarnessInlineActionButton(
      title: "End Session",
      actionID: .endSession(sessionID: detail.session.sessionId),
      store: store,
      variant: .bordered,
      tint: .secondary,
      isExternallyDisabled: !areSessionActionsAvailable,
      accessibilityIdentifier: HarnessMonitorAccessibility.endSessionButton,
      help: unavailableActionHelp,
      action: { requestEndSessionConfirmation() }
    )
  }

  private func awaitingLeaderSummary(_ message: String) -> some View {
    Label {
      Text(message)
        .scaledFont(.system(.body, design: .rounded, weight: .medium))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    } icon: {
      Image(systemName: "hourglass")
        .foregroundStyle(HarnessMonitorTheme.accent)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(HarnessMonitorTheme.cardPadding)
    .background(
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
        .fill(HarnessMonitorTheme.accent.opacity(0.08))
    )
  }

  private func observerSummary(_ observer: ObserverSummary) -> some View {
    Button(action: inspectObserver) {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: HarnessMonitorTheme.spacingLG) {
            summaryLabel("Observe", value: observer.observeId)
            summaryLabel("Open Issues", value: "\(observer.openIssueCount)")
            summaryLabel("Muted", value: "\(observer.mutedCodeCount)")
            summaryLabel("Workers", value: "\(observer.activeWorkerCount)")
            Spacer()
            summaryLabel(
              "Last Sweep",
              value: formatTimestamp(observer.lastScanTime, configuration: dateTimeConfiguration)
            )
          }
          VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
            HStack(spacing: HarnessMonitorTheme.spacingLG) {
              summaryLabel("Observe", value: observer.observeId)
              summaryLabel("Open Issues", value: "\(observer.openIssueCount)")
            }
            HStack(spacing: HarnessMonitorTheme.spacingLG) {
              summaryLabel("Muted", value: "\(observer.mutedCodeCount)")
              summaryLabel("Workers", value: "\(observer.activeWorkerCount)")
              summaryLabel(
                "Last Sweep",
                value: formatTimestamp(observer.lastScanTime, configuration: dateTimeConfiguration)
              )
            }
          }
        }
        if let openIssues = observer.openIssues, !openIssues.isEmpty {
          Text(openIssues.prefix(2).map(\.summary).joined(separator: " · "))
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .lineLimit(1)
        }
        if let mutedCodes = observer.mutedCodes, !mutedCodes.isEmpty {
          Text("Muted: \(mutedCodes.prefix(3).joined(separator: ", "))")
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .lineLimit(1)
        }
      }
      .accessibilityElement(children: .combine)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(HarnessMonitorTheme.cardPadding)
    }
    .harnessInteractiveCardButtonStyle()
    .accessibilityIdentifier("harness.session.observe.summary")
    .accessibilityValue("interactive=button, chrome=content-card")
  }

  private func pendingTransferSummary(_ pendingTransfer: PendingLeaderTransfer) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      HStack {
        Label("Pending Leader Transfer", systemImage: "arrow.left.arrow.right")
          .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
        Spacer()
        Text(formatTimestamp(pendingTransfer.requestedAt, configuration: dateTimeConfiguration))
          .scaledFont(.caption.monospaced())
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
      let requested = pendingTransfer.requestedBy
      let newLeader = pendingTransfer.newLeaderId
      let current = pendingTransfer.currentLeaderId
      Text("\(requested) requested \(newLeader) to replace \(current).")
        .scaledFont(.system(.body, design: .rounded, weight: .medium))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      if let reason = pendingTransfer.reason, !reason.isEmpty {
        Text(reason)
          .scaledFont(.system(.footnote, design: .rounded, weight: .semibold))
          .foregroundStyle(HarnessMonitorTheme.warmAccent)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.leading, HarnessMonitorTheme.spacingLG)
    .overlay(alignment: .leading) {
      RoundedRectangle(cornerRadius: 999, style: .continuous)
        .fill(HarnessMonitorTheme.warmAccent)
        .frame(width: 4)
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.pendingLeaderTransferCard)
  }

  private func summaryLabel(_ title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title.uppercased())
        .scaledFont(.caption2.weight(.bold))
        .tracking(HarnessMonitorTheme.uppercaseTracking)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Text(value)
        .scaledFont(.system(.callout, design: .rounded, weight: .semibold))
    }
  }
}

private func sessionHeaderMetadata(_ session: SessionSummary) -> String {
  "\(session.projectName) • \(session.worktreeDisplayName) • \(session.sessionId)"
}

@MainActor
private func sessionLeaderAndActivityLine(
  _ session: SessionSummary,
  configuration: HarnessMonitorDateTimeConfiguration
) -> String {
  let leader = session.leaderId ?? "unassigned"
  let activity = formatTimestamp(session.lastActivityAt, configuration: configuration)
  return "Leader: \(leader) • Updated \(activity)"
}

#Preview("Cockpit header") {
  SessionCockpitHeaderCard(
    store: HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded),
    detail: PreviewFixtures.detail,
    isSessionReadOnly: false,
    observeSelectedSession: {},
    requestEndSessionConfirmation: {},
    inspectObserver: {},
    createTask: {}
  )
  .padding()
  .frame(width: 960)
}
