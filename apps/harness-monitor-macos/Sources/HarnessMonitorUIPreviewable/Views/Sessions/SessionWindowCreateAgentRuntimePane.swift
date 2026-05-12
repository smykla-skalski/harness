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
    if normalizedLaunchSelection.isCodexNative {
      return store.codexUnavailable ? .codex : nil
    }
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
