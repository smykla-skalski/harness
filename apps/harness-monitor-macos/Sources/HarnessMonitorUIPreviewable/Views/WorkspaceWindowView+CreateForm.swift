import HarnessMonitorKit
import SwiftUI

extension WorkspaceWindowView {
  var createPane: some View {
    WorkspaceWindowCreatePane(
      store: store,
      viewModel: viewModel,
      displayState: displayState,
      focusedFieldBinding: focusedFieldBinding,
      startAction: { startTui() },
      renderSessionActionBanner: { message in
        AnyView(createPaneSessionActionBanner(message: message))
      },
      renderAcpUnavailableBanner: {
        AnyView(acpUnavailableBanner)
      },
      renderAgentTuiUnavailableBanner: {
        AnyView(agentTuiUnavailableBanner)
      },
      renderCodexUnavailableBanner: {
        AnyView(codexUnavailableBanner)
      }
    )
  }
}

struct WorkspaceWindowCreatePane: View {
  typealias ViewModel = WorkspaceWindowView.ViewModel
  typealias DisplayState = WorkspaceWindowView.AgentTuiDisplayState
  typealias Field = WorkspaceWindowView.Field

  let store: HarnessMonitorStore
  let viewModel: ViewModel
  let displayState: DisplayState
  let focusedFieldBinding: FocusState<Field?>.Binding
  let startAction: () -> Void
  let renderSessionActionBanner: (String) -> AnyView
  let renderAcpUnavailableBanner: () -> AnyView
  let renderAgentTuiUnavailableBanner: () -> AnyView
  let renderCodexUnavailableBanner: () -> AnyView

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXL) {
        createPaneHeader
        createModeCard
        createPaneBanners

        switch viewModel.createMode {
        case .terminal:
          terminalCreateContent
        case .codex:
          codexCreateContent
        }
      }
      .padding(HarnessMonitorTheme.spacingLG)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .scrollIndicators(.automatic)
    .accessibilityElement(children: .contain)
    .harnessMCPList(
      HarnessMonitorAccessibility.agentTuiLaunchPane,
      label: "New agent pane"
    )
  }
}

extension WorkspaceWindowCreatePane {
  private static let splitCreateLayoutMinimumWidth: CGFloat = 700

  private var createPaneHeader: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text(viewModel.createMode.headerTitle)
        .scaledFont(.system(.title2, design: .rounded, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      Text(createPaneDescription)
        .scaledFont(.subheadline)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .frame(maxWidth: 620, alignment: .leading)
    }
  }

  private var createModeCard: some View {
    @Bindable var formModel = viewModel
    return AgentsCreateSectionCard {
      AgentsCreateFieldBlock(
        title: "Create",
        help: "Choose whether this window starts an agent or a Codex run."
      ) {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.sectionSpacing) {
          Picker("Create", selection: $formModel.createMode) {
            ForEach(AgentTuiCreateMode.allCases) { mode in
              Text(mode.title)
                .tag(mode)
                .accessibilityIdentifier(
                  HarnessMonitorAccessibility.segmentedOption(
                    HarnessMonitorAccessibility.agentTuiCreateModePicker,
                    option: mode.title
                  )
                )
                .harnessMCPButton(
                  HarnessMonitorAccessibility.segmentedOption(
                    HarnessMonitorAccessibility.agentTuiCreateModePicker,
                    option: mode.title
                  ),
                  label: mode.title,
                  pressAction: { formModel.createMode = mode }
                )
            }
          }
          .pickerStyle(.segmented)
          .harnessNativeFormControl()
          .harnessMCPButton(
            HarnessMonitorAccessibility.agentTuiCreateModePicker,
            label: "Create"
          )

          AgentsCreateSummaryFactsView(facts: createSummaryFacts)
        }
      }
    }
  }

  @ViewBuilder
  func createPaneColumns<Leading: View, Trailing: View>(
    leadingMaxWidth: CGFloat? = nil,
    @ViewBuilder leading: () -> Leading,
    @ViewBuilder trailing: () -> Trailing
  ) -> some View {
    // Let layout choose the best arrangement without feeding measured width
    // back into observed state, which can create a geometry/update loop.
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingXL) {
        leading()
          .frame(maxWidth: leadingMaxWidth, alignment: .leading)
        trailing()
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(
        minWidth: Self.splitCreateLayoutMinimumWidth,
        maxWidth: .infinity,
        alignment: .leading
      )

      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXL) {
        leading()
        trailing()
      }
    }
  }

  private var createSummaryFacts: [AgentsCreateSummaryFact] {
    switch viewModel.createMode {
    case .terminal:
      terminalCreateSummaryFacts
    case .codex:
      codexCreateSummaryFacts
    }
  }

  private var terminalCreateSummaryFacts: [AgentsCreateSummaryFact] {
    [
      AgentsCreateSummaryFact(title: "Provider", value: selectedAgentLaunchTitle),
      AgentsCreateSummaryFact(title: "Starts with", value: selectedTransportSummaryTitle),
    ]
  }

  var selectedTransportSummaryTitle: String {
    guard let option = selectedCapabilityOption else {
      return "Choose a provider"
    }

    let selectedChoice = option.transportChoice(
      for: option.normalizedSelection(for: viewModel.selectedLaunchSelection)
    )
    return selectedChoice.id.isAcp ? "Project Access" : "Terminal"
  }

  @ViewBuilder private var createPaneBanners: some View {
    if let message = createPaneSessionActionUnavailableNote {
      renderSessionActionBanner(message)
    }
    if viewModel.createMode == .terminal {
      if viewModel.selectedLaunchSelection.isAcp {
        if displayState.acpUnavailable {
          renderAcpUnavailableBanner()
        }
      } else if displayState.agentTuiUnavailable {
        renderAgentTuiUnavailableBanner()
      }
    }
    if viewModel.createMode == .codex && displayState.codexUnavailable {
      renderCodexUnavailableBanner()
    }
  }
}
