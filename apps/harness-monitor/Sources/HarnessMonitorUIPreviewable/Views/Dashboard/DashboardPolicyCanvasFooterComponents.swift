import HarnessMonitorKit
import HarnessMonitorPolicyCanvas
import SwiftUI

struct DashboardPolicyCanvasFooterSaveStatus: View {
  let activity: PolicyCanvasSaveActivity

  var body: some View {
    let presentation = activity.presentation
    Group {
      if presentation.isVisible {
        HStack(spacing: 6) {
          leadingGlyph(presentation)
          Text(presentation.label)
            .scaledFont(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.horizontal, HarnessMonitorTheme.spacingMD)
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityIdentifier(HarnessMonitorAccessibility.dashboardPolicyCanvasFooterSaveStatus)
      }
    }
  }

  @ViewBuilder
  private func leadingGlyph(_ presentation: PolicyCanvasSaveStatusPresentation) -> some View {
    if presentation.showsSpinner {
      HarnessMonitorSpinner(size: 14, tint: .secondary)
    } else if let symbolName = presentation.symbolName {
      Image(systemName: symbolName)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}

struct DashboardPolicyCanvasFooterToolsMenuButton: View {
  @ScaledMetric(relativeTo: .callout)
  private var buttonHorizontalPadding = 14.0
  @ScaledMetric(relativeTo: .callout)
  private var buttonMinWidth = 44.0

  let viewModel: PolicyCanvasViewModel
  @Binding var isAutomationPolicySheetPresented: Bool
  let onExport: (@MainActor () -> Void)?
  let onImport: (@MainActor () -> Void)?

  @Environment(\.fontScale)
  private var fontScale
  @State private var isHovering = false

  var body: some View {
    Menu {
      PolicyCanvasToolsMenuContent(
        viewModel: viewModel,
        isAutomationPolicySheetPresented: $isAutomationPolicySheetPresented,
        onExport: onExport,
        onImport: onImport
      )
    } label: {
      Image(systemName: "gearshape")
        .font(.callout.weight(.medium))
        .padding(.horizontal, buttonHorizontalPadding)
        .frame(minWidth: buttonMinWidth)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
    }
    .buttonStyle(
      DashboardPolicyCanvasFooterTabButtonStyle(
        isSelected: false,
        isHovering: isHovering,
        showsLeadingSeparator: true,
        showsTrailingSeparator: false
      )
    )
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .frame(maxHeight: .infinity)
    .foregroundStyle(.primary)
    .help("Policy tools")
    .accessibilityLabel("Policy tools")
    .accessibilityHint("Open policy tools")
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasToolsButton)
    .environment(
      \.harnessNativeFormControlFont,
      HarnessMonitorTextSize.scaledFont(.callout.weight(.semibold), by: fontScale)
    )
    .environment(\.harnessNativeFormControlSize, .small)
    .harnessNativeFormControl()
    .onHover { hovering in
      isHovering = hovering
    }
    .onDisappear {
      isHovering = false
    }
  }
}

struct DashboardPolicyCanvasFooterCreateTab: View {
  @ScaledMetric(relativeTo: .callout)
  private var tabHorizontalPadding = 14.0
  @ScaledMetric(relativeTo: .callout)
  private var tabMinWidth = 44.0

  let isDisabled: Bool
  let createCanvas: @MainActor () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: createCanvas) {
      Image(systemName: "plus")
        .font(.callout.weight(.medium))
        .padding(.horizontal, tabHorizontalPadding)
        .frame(minWidth: tabMinWidth)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
    }
    .buttonStyle(
      DashboardPolicyCanvasFooterTabButtonStyle(
        isSelected: false,
        isHovering: isHovering,
        showsTrailingSeparator: false
      )
    )
    .frame(maxHeight: .infinity)
    .foregroundStyle(.primary)
    .disabled(isDisabled)
    .help("Create a new policy canvas")
    .accessibilityLabel("New Canvas")
    .accessibilityHint("Create a new policy canvas")
    .onHover { hovering in
      isHovering = hovering && !isDisabled
    }
    .onChange(of: isDisabled) { _, disabled in
      guard disabled else { return }
      isHovering = false
    }
    .onDisappear {
      isHovering = false
    }
  }
}

struct DashboardPolicyCanvasFooterTab: View {
  @ScaledMetric(relativeTo: .callout)
  private var tabHorizontalPadding = 14.0
  @ScaledMetric(relativeTo: .callout)
  private var tabMaxWidth = 220.0

  let canvas: PolicyCanvasSummary
  let isSelected: Bool
  let isActive: Bool
  let isEditing: Bool
  let canRename: Bool
  let showsLeadingSeparator: Bool
  let select: @MainActor () -> Void
  let beginRename: @MainActor () -> Void
  let submitRename: @MainActor (String) -> Void
  let cancelRename: @MainActor () -> Void

  @State private var isHovering = false

  var body: some View {
    tabContent
      .frame(maxHeight: .infinity)
      .foregroundStyle(.primary)
      .help(helpText)
      .onHover { hovering in
        isHovering = hovering && !isEditing
      }
      .onChange(of: isEditing) { _, editing in
        if editing {
          isHovering = false
        }
      }
      .onDisappear {
        isHovering = false
      }
  }

  @ViewBuilder private var tabContent: some View {
    if isEditing {
      DashboardPolicyCanvasFooterTabTitleEditor(
        title: canvas.title,
        maxWidth: tabMaxWidth,
        horizontalPadding: tabHorizontalPadding,
        accessibilityIdentifier: HarnessMonitorAccessibility.dashboardPolicyCanvasFooterRenameField(
          canvas.canvasId
        ),
        submit: submitRename,
        cancel: cancelRename
      )
      .dashboardPolicyCanvasFooterTabChrome(
        isSelected: isSelected,
        isLive: isLive,
        isHovering: false,
        isPressed: false,
        showsLeadingSeparator: showsLeadingSeparator && isSelected
      )
    } else {
      titleButton
    }
  }

  private var titleButton: some View {
    Text(canvas.title)
      .font(.callout.weight(.medium))
      .lineLimit(1)
      .truncationMode(.tail)
      .padding(.horizontal, tabHorizontalPadding)
      .frame(maxWidth: tabMaxWidth, alignment: .leading)
      .frame(maxHeight: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .dashboardPolicyCanvasFooterTabChrome(
        isSelected: isSelected,
        isLive: isLive,
        isHovering: isHovering,
        isPressed: false,
        showsLeadingSeparator: showsLeadingSeparator && isSelected
      )
      .overlay {
        DashboardPolicyCanvasFooterTabClickTarget(
          onHover: { hovering in
            isHovering = hovering
          },
          singleClick: select,
          doubleClick: {
            guard canRename else { return }
            beginRename()
          }
        )
        .accessibilityHidden(true)
      }
      .accessibilityLabel(canvas.title)
      .accessibilityValue(accessibilityValue)
      .accessibilityAddTraits(.isButton)
      .accessibilityAction {
        select()
      }
  }

  private var isLive: Bool {
    canvas.mode == .enforced
  }

  private var helpText: String {
    "\(canvas.title) - \(metadataText)"
  }

  private var accessibilityValue: String {
    var parts: [String] = []
    if isActive {
      parts.append("Active")
    }
    if isSelected {
      parts.append("Selected")
    }
    parts.append(metadataText)
    return parts.joined(separator: ", ")
  }

  private var metadataText: String {
    var parts = [
      isLive ? "Live" : "Draft",
      "revision \(canvas.revision)",
      "\(canvas.nodeCount) nodes",
      "\(canvas.groupCount) groups",
    ]
    if let latestSimulationSucceeded = canvas.latestSimulationSucceeded {
      if latestSimulationSucceeded {
        parts.append("latest simulation passed")
      } else {
        parts.append("latest simulation found issues")
      }
    }
    return parts.joined(separator: ", ")
  }
}

struct DashboardPolicyCanvasFooterTabButtonStyle: ButtonStyle {
  let isSelected: Bool
  var isLive = false
  let isHovering: Bool
  var showsLeadingSeparator = false
  var showsTrailingSeparator = true

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .dashboardPolicyCanvasFooterTabChrome(
        isSelected: isSelected,
        isLive: isLive,
        isHovering: isHovering,
        isPressed: configuration.isPressed,
        showsLeadingSeparator: showsLeadingSeparator,
        showsTrailingSeparator: showsTrailingSeparator
      )
  }
}
