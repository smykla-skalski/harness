import HarnessMonitorKit
import SwiftUI

struct SessionWindowCreateAgentRuntimePane: View {
  let store: HarnessMonitorStore
  let state: SessionWindowStateCache
  let draft: SessionCreateDraft

  var body: some View {
    HarnessMonitorColumnScrollView(
      horizontalPadding: HarnessMonitorTheme.spacingLG,
      verticalPadding: HarnessMonitorTheme.spacingLG,
      constrainContentWidth: false,
      readableWidth: false,
      topScrollEdgeEffect: .soft,
      scrollSurfaceLabel: "Agent provider selection"
    ) {
      SessionWindowCreateAgentRuntimeContent(
        store: store,
        state: state,
        draft: draft,
        embeddedInForm: false
      )
    }
  }
}

struct SessionWindowCreateAgentRuntimeContent: View {
  let store: HarnessMonitorStore
  let state: SessionWindowStateCache
  let draft: SessionCreateDraft
  let embeddedInForm: Bool

  private var catalogState: SessionWindowAgentCreateCatalogState {
    state.agentCreateCatalog
  }

  private var activeAgentOptions: [AgentCapabilityOption] {
    SessionWindowCreateFormCatalogs.activeAgentOptions(
      catalogState: catalogState,
      store: store
    )
  }

  private var normalizedLaunchSelection: AgentLaunchSelection {
    SessionWindowCreateFormCatalogs.normalizedLaunchSelection(
      draft: draft,
      options: activeAgentOptions,
      didPickLaunchSelectionManually: state.didPickCreateLaunchSelectionManually(
        for: draft.kind
      )
    )
  }

  private var selectedCapabilityOption: AgentCapabilityOption? {
    SessionWindowCreateFormCatalogs.selectedCapabilityOption(
      selection: normalizedLaunchSelection,
      options: activeAgentOptions
    )
  }

  private var bridgeBannerKind: SessionCreateBridgeBannerKind? {
    guard draft.kind == .agent else { return nil }
    if normalizedLaunchSelection.isAcp {
      return store.acpUnavailable ? .acp : nil
    }
    return store.agentTuiUnavailable ? .agentTui : nil
  }

  private var launchSelection: Binding<AgentLaunchSelection> {
    Binding(
      get: { normalizedLaunchSelection },
      set: { state.persistCreateLaunchSelection($0, for: draft) }
    )
  }

  private var selectedProviderID: String? {
    selectedCapabilityOption?.id
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXL) {
      header

      if let bridgeBannerKind {
        SessionCreateBridgeBanner(
          store: store,
          copy: bridgeBannerKind.copy(store: store)
        )
      }

      providerSection
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .accessibilityElement(children: .contain)
    .accessibilityTestProbe(
      HarnessMonitorAccessibility.sessionWindowCreateProviderPane,
      label: "New agent provider pane"
    )
    .task(id: draft.kind == .agent ? draft.sessionID : "") {
      guard draft.kind == .agent else { return }
      await SessionWindowCreateFormCatalogs.loadAgentCatalogStateIfNeeded(
        store: store,
        state: state,
        draft: draft
      )
    }
  }

  @ViewBuilder private var header: some View {
    if embeddedInForm {
      compactHeader
    } else {
      paneHeader
    }
  }

  private var paneHeader: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text(paneTitle)
        .scaledFont(.title2.weight(.semibold))
        .accessibilityAddTraits(.isHeader)

      availabilityNote
    }
  }

  private var compactHeader: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text(paneTitle)
        .scaledFont(.headline.weight(.semibold))
        .accessibilityAddTraits(.isHeader)
      Text(compactDescription)
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .fixedSize(horizontal: false, vertical: true)
      availabilityNote
    }
  }

  private var paneTitle: String {
    "New agent"
  }

  private var compactDescription: String {
    "Choose a provider below. ACP is preferred when available; finish configuration in the form."
  }

  @ViewBuilder private var availabilityNote: some View {
    if catalogState.isLoading && !catalogState.hasLoaded {
      Label("Checking available runtimes", systemImage: "clock")
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
  }

  @ViewBuilder private var providerSection: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
      SessionWindowCreateSidebarSectionHeader(title: "Provider")
      providerRows
    }
  }

  private var providerRows: some View {
    VStack(spacing: HarnessMonitorTheme.spacingXS) {
      ForEach(activeAgentOptions) { option in
        Button {
          selectProvider(option)
        } label: {
          SessionWindowCreateProviderListRow(
            option: option,
            isSelected: selectedProviderID == option.id
          )
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(SessionWindowCreateProviderListRow.accessibilityLabel(for: option))
        .accessibilityValue(
          selectedProviderID == option.id ? "Selected" : ""
        )
        .accessibilityHint("Chooses \(option.title)")
      }
    }
    .padding(.horizontal, -HarnessMonitorTheme.spacingSM)
  }

  private func selectProvider(_ option: AgentCapabilityOption) {
    launchSelection.wrappedValue = option.normalizedSelection(for: launchSelection.wrappedValue)
  }
}

private struct SessionWindowCreateSidebarSectionHeader: View {
  let title: String

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      Text(title.uppercased())
        .scaledFont(.caption2.weight(.semibold))
        .tracking(HarnessMonitorTheme.uppercaseTracking)
        .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
        .accessibilityAddTraits(.isHeader)

      Rectangle()
        .fill(Color.secondary.opacity(0.18))
        .frame(height: 1)
        .accessibilityHidden(true)
    }
  }
}

struct SessionWindowCreateProviderListRow: View {
  let option: AgentCapabilityOption
  let isSelected: Bool

  private var rowTint: Color {
    isSelected ? HarnessMonitorTheme.accent.opacity(0.10) : .clear
  }

  private var statusTint: Color {
    option.availabilityState.tint
  }

  var body: some View {
    HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
      Image(systemName: Self.providerIconName(for: option))
        .scaledFont(.body)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .frame(width: 16, alignment: .center)
        .padding(.top, 1)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingSM) {
          Text(option.title)
            .scaledFont(.body.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(HarnessMonitorTheme.ink)

          Spacer(minLength: HarnessMonitorTheme.spacingSM)

          Text(option.availabilityState.compactTitle)
            .scaledFont(.caption.weight(.semibold))
            .foregroundStyle(statusTint)
            .multilineTextAlignment(.trailing)
            .lineLimit(1)
            .truncationMode(.tail)
            .fixedSize(horizontal: true, vertical: false)
        }

        Text(Self.providerSubtitle(for: option))
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
    .padding(.horizontal, HarnessMonitorTheme.spacingSM)
    .padding(.vertical, HarnessMonitorTheme.spacingXS)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(rowTint)
    .clipShape(.rect(cornerRadius: HarnessMonitorTheme.cornerRadiusSM))
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  static func providerSubtitle(for option: AgentCapabilityOption) -> String {
    switch option.availabilityState {
    case .projectAccessAvailable:
      return "Terminal and ACP are available."
    case .checkingAccess:
      return "ACP is still being checked."
    case .setupRequired:
      return "ACP needs CLI setup."
    case .bridgeAccessRequired:
      return "ACP needs bridge access."
    case .terminalOnly:
      if option.acpChoice != nil {
        return "ACP is not available here yet."
      }
      return "This provider opens in Terminal only."
    case .unavailable:
      return option.projectAccessGuidanceText ?? "This provider is not available here yet."
    }
  }

  static func providerSummary(for option: AgentCapabilityOption) -> String {
    providerSubtitle(for: option)
  }

  static func providerIconName(for option: AgentCapabilityOption) -> String {
    switch option.id {
    case "codex":
      return "terminal"
    case "claude":
      return "sparkles"
    case "gemini":
      return "diamond"
    case "copilot":
      return "paperplane"
    case "vibe":
      return "waveform"
    case "opencode":
      return "chevron.left.forwardslash.chevron.right"
    default:
      return "terminal"
    }
  }

  static func accessibilityLabel(for option: AgentCapabilityOption) -> String {
    [option.title, providerSubtitle(for: option), option.availabilityState.compactTitle]
      .compactMap { $0 }
      .joined(separator: ", ")
  }
}

struct SessionWindowCreateTransportChoiceButton: View {
  let providerTitle: String
  let choice: AgentCapabilityTransportChoice
  let isSelected: Bool
  let isEnabled: Bool
  let unavailableReason: String?
  let onSelect: () -> Void

  private var shortTitle: String {
    choice.id.isAcp ? "ACP" : "Terminal"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Button {
        onSelect()
      } label: {
        HStack(spacing: HarnessMonitorTheme.spacingXS) {
          Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          Text(shortTitle)
        }
        .frame(maxWidth: .infinity)
      }
      .harnessActionButtonStyle(
        variant: isSelected ? .prominent : .bordered,
        tint: isSelected ? nil : .secondary
      )
      .disabled(!isEnabled)
      .accessibilityLabel("\(providerTitle), \(choice.title)")
      .accessibilityValue(isSelected ? "Selected" : "")
      .accessibilityHint(
        isEnabled ? "" : (unavailableReason ?? "Unavailable")
      )

      if !isEnabled, let unavailableReason {
        Text(unavailableReason)
          .scaledFont(.caption2)
          .foregroundStyle(HarnessMonitorTheme.caution)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
