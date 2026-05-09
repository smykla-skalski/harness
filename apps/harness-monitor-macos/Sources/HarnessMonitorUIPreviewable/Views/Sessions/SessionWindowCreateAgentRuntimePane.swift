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
      options: activeAgentOptions
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
    if draft.useCodex {
      return store.codexUnavailable ? .codex : nil
    }
    if normalizedLaunchSelection.isAcp {
      return store.acpUnavailable ? .acp : nil
    }
    return store.agentTuiUnavailable ? .agentTui : nil
  }

  private var useCodex: Binding<Bool> {
    Binding(
      get: { draft.useCodex },
      set: { updateDraft(useCodex: $0) }
    )
  }

  private var launchSelection: Binding<AgentLaunchSelection> {
    Binding(
      get: { normalizedLaunchSelection },
      set: { updateDraft(runtime: $0.storageKey) }
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

      if draft.useCodex {
        codexSupportContent
      } else {
        providerSection
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .task(id: draft.kind == .agent ? draft.sessionID : "") {
      guard draft.kind == .agent else { return }
      await SessionWindowCreateFormCatalogs.loadAgentCatalogStateIfNeeded(
        store: store,
        state: state,
        draft: draft
      )
    }
  }

  @ViewBuilder
  private var header: some View {
    if embeddedInForm {
      compactHeader
    } else {
      paneHeader
    }
  }

  private var paneHeader: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
        Text(paneTitle)
          .scaledFont(.title2.weight(.semibold))
          .accessibilityAddTraits(.isHeader)
        Spacer(minLength: HarnessMonitorTheme.spacingSM)
        modePicker
          .fixedSize(horizontal: true, vertical: false)
      }

      availabilityNote
    }
  }

  private var compactHeader: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      modePicker
      Text(compactDescription)
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .fixedSize(horizontal: false, vertical: true)
      availabilityNote
    }
  }

  private var paneTitle: String {
    draft.useCodex ? "New Codex run" : "New terminal agent"
  }

  private var compactDescription: String {
    if draft.useCodex {
      return "The form below holds the prompt and configuration for this run."
    }
    return "Choose a provider below, then finish configuration in the form."
  }

  @ViewBuilder
  private var availabilityNote: some View {
    if catalogState.isLoading && !catalogState.hasLoaded {
      Label("Checking available runtimes", systemImage: "clock")
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
    }
  }

  private var modePicker: some View {
    Picker("Create", selection: useCodex) {
      Text("Terminal")
        .tag(false)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.segmentedOption(
            HarnessMonitorAccessibility.sessionWindowCreateModePicker,
            option: "Terminal"
          )
        )
        .harnessMCPButton(
          HarnessMonitorAccessibility.segmentedOption(
            HarnessMonitorAccessibility.sessionWindowCreateModePicker,
            option: "Terminal"
          ),
          label: "Terminal",
          pressAction: { useCodex.wrappedValue = false }
        )
      Text("Codex")
        .tag(true)
        .accessibilityIdentifier(
          HarnessMonitorAccessibility.segmentedOption(
            HarnessMonitorAccessibility.sessionWindowCreateModePicker,
            option: "Codex"
          )
        )
        .harnessMCPButton(
          HarnessMonitorAccessibility.segmentedOption(
            HarnessMonitorAccessibility.sessionWindowCreateModePicker,
            option: "Codex"
          ),
          label: "Codex",
          pressAction: { useCodex.wrappedValue = true }
        )
    }
    .labelsHidden()
    .pickerStyle(.segmented)
    .harnessNativeFormControl()
    .harnessMCPButton(
      HarnessMonitorAccessibility.sessionWindowCreateModePicker,
      label: "Create"
    )
    .accessibilityLabel("Create")
    .accessibilityIdentifier(HarnessMonitorAccessibility.sessionWindowCreateModePicker)
  }

  @ViewBuilder
  private var providerSection: some View {
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

  private var codexSupportContent: some View {
    SessionWindowCreateSectionCard {
      SessionWindowCreateSectionHeading(
        title: "Codex",
        description:
          "The form holds the prompt plus the run mode, model, and effort for this draft."
      )
    }
  }

  private func selectProvider(_ option: AgentCapabilityOption) {
    launchSelection.wrappedValue = option.normalizedSelection(for: launchSelection.wrappedValue)
  }

  private func updateDraft(
    runtime: String? = nil,
    useCodex: Bool? = nil
  ) {
    var next = draft
    if let runtime {
      next.runtime = runtime
    }
    if let useCodex {
      next.useCodex = useCodex
    }
    state.updateCreateDraft(next)
  }
}

private struct SessionWindowCreateSectionCard<Content: View>: View {
  private let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    content
      .padding(.vertical, HarnessMonitorTheme.spacingSM)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct SessionWindowCreateSectionHeading: View {
  let title: String
  let description: String?

  init(title: String, description: String? = nil) {
    self.title = title
    self.description = description
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text(title)
        .scaledFont(.headline)
        .accessibilityAddTraits(.isHeader)

      if let description {
        Text(description)
          .scaledFont(.subheadline)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
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

struct SessionWindowCreateFieldBlock<Content: View>: View {
  let title: String
  let help: String?
  private let content: Content

  init(
    title: String,
    help: String? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.help = help
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text(title)
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)

      content

      if let help {
        Text(help)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
      }
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
      return "Terminal and project access are available."
    case .checkingAccess:
      return "Project access is still being checked."
    case .setupRequired:
      return "Project access needs CLI setup."
    case .bridgeAccessRequired:
      return "Project access needs bridge access."
    case .terminalOnly:
      if option.acpChoice != nil {
        return "Project access is not available here yet."
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

struct SessionWindowCreateProviderButtonList: View {
  let options: [AgentCapabilityOption]
  let selectedProviderID: String?
  let onSelect: (AgentCapabilityOption) -> Void

  var body: some View {
    VStack(spacing: HarnessMonitorTheme.spacingXS) {
      ForEach(options) { option in
        Button {
          onSelect(option)
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
        .accessibilityValue(selectedProviderID == option.id ? "Selected" : "")
        .accessibilityHint("Chooses \(option.title)")
      }
    }
  }
}

struct SessionWindowCreateTransportChoiceButton: View {
  let providerTitle: String
  let choice: AgentCapabilityTransportChoice
  let selection: Binding<AgentLaunchSelection>
  let isSelected: Bool
  let isEnabled: Bool
  let unavailableReason: String?

  private var shortTitle: String {
    choice.id.isAcp ? "Project access" : "Terminal"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Button {
        selection.wrappedValue = choice.id
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

struct SessionWindowCreateDiagnosticsDisclosure: View {
  let option: AgentCapabilityOption
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @State private var isExpanded = false

  var body: some View {
    if let doctorProbeText = option.doctorProbeText {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        Button(isExpanded ? "Hide setup details" : "Show setup details") {
          if reduceMotion {
            isExpanded.toggle()
          } else {
            withAnimation(.easeOut(duration: 0.18)) {
              isExpanded.toggle()
            }
          }
        }
        .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
        .controlSize(HarnessMonitorControlMetrics.compactControlSize)
        .accessibilityLabel(
          "\(isExpanded ? "Hide" : "Show") setup details for \(option.title)"
        )
        .accessibilityHint(doctorProbeText)

        if isExpanded {
          Text(doctorProbeText)
            .scaledFont(.caption.monospaced())
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
      }
    }
  }
}
